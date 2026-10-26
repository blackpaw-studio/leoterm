import Foundation
import LeoKit

/// A connected machine's daemon client, activity stream and Leo Chat client.
/// `chat` has no default: a missing production client must not compile
/// silently, or that machine's chat would sit at "isn't connected".
struct LeoMachineDaemon: Sendable {
    let daemon: any LeoDaemonClient
    let activitySource: LeoSidebarActivitySource
    let chat: any LeoChatClient
}

/// Builds a remote machine's `LeoMachineDaemon` for its forwarded socket.
typealias LeoRemoteDaemonFactory = @Sendable (_ host: LeoHostID, _ socketPath: String) async -> LeoMachineDaemon

/// Every machine connects on its own: its state transitions reach only its
/// own feed, client and Chat client. Leo Chat follows each agent's machine:
/// a machine's chat binds when it connects and unbinds when it drops.
extension LeoRuntime {
    /// Opens Leo Settings on its Machines tab, selecting `host` when given.
    func presentMachinesSettings(selecting host: LeoHostID? = nil) {
        settingsWindow.show(selecting: host)
    }

    /// The registry's machines changed (launch, or Settings saved). The
    /// model learns them before their feeds can deliver; a machine that
    /// left, or was disabled, loses its feed and client.
    func machinesChanged(_ all: [LeoHostID]) {
        let shown = all.filter { host in
            host == .local || (feedsRemoteMachines && machines.configuration(for: host)?.isEnabled != false)
        }
        let gone = feeds.hosts.filter { !shown.contains($0) }
        model.setMachines(shown)
        feeds.setMachines(shown)
        statsPoller.setMachines(shown)
        gone.forEach {
            clients.unbind($0)
            chatMachineDisconnected($0)
            agentBrowsers.machineDisconnected($0)
        }
    }

    /// A machine connected, failed, was disabled or came back: the spawn
    /// sheet's Machine field reads these off the model, for the machines it
    /// shows.
    func machineStatusesChanged(_ statuses: [LeoHostID: LeoMachineStatus]) {
        model.setMachineStatuses(feedsRemoteMachines ? statuses : statuses.filter { $0.key == .local })
    }

    /// A machine's feed dropped while the registry still held its
    /// connection up (the daemon died behind a live tunnel), or its list
    /// landed again: the registry fails it into its retry backoff, or lets
    /// that backoff start over.
    func feedSnapshotLanded(_ snapshot: LeoSidebarSnapshot, for host: LeoHostID) {
        guard !isShutDown else { return }
        #if DEBUG
        if LeoForcedDisconnectFixture.isForced(snapshot.connectivity) { return }
        #endif
        switch daemonLoss.observe(snapshot, for: host) {
        case .stoppedAnswering(let reason)?: machines.daemonStoppedAnswering(host, reason: reason)
        case .answered?: machines.daemonAnswered(host)
        case nil: break
        }
    }

    /// Applies one machine's connection-state transition to its feed (and,
    /// once connected, to its client). `.connecting`/`.failed` carry no
    /// async work of their own and are forwarded at once; `.connected`
    /// needs that machine's daemon client built first (see
    /// `applyConnected`). A machine that isn't shown is left alone.
    func applyConnection(host: LeoHostID, generation: Int, state: LeoHostConnectionState) {
        guard !isShutDown, feeds.contains(host) else { return }
        let sequence = connectionSequences[host, default: 0] + 1
        connectionSequences[host] = sequence
        switch state {
        case .connecting:
            chatMachineDisconnected(host)
            agentBrowsers.machineDisconnected(host)
            feeds.updateConnection(host: host, generation: generation, phase: .connecting)
            statsPoller.reconcile()
        case .failed(let message, _):
            chatMachineDisconnected(host)
            agentBrowsers.machineDisconnected(host)
            feeds.updateConnection(host: host, generation: generation, phase: .failed(message: message))
            statsPoller.reconcile()
        case .connected(let socketPath):
            Task { [weak self] in
                await self?.applyConnected(host: host, generation: generation, socketPath: socketPath, sequence: sequence)
            }
        }
    }

    /// Builds `host`'s client -- This Mac's precomputed one, or a fresh
    /// per-socket client (with its own flavor detection) for a remote
    /// machine -- and only then binds it to the machine's client, actions
    /// and feed. Guarded by `host`'s connection sequence, captured BEFORE
    /// the only `await` in this path: if ANY newer transition for that
    /// machine (connecting, connected or failed -- not just a generation
    /// change) has since been seen, this stale result is dropped.
    private func applyConnected(host: LeoHostID, generation: Int, socketPath: String, sequence: Int) async {
        let connected = host == .local
            ? LeoMachineDaemon(daemon: localDaemon, activitySource: localActivitySource, chat: localChatClient)
            : await remoteDaemon(host, socketPath)
        guard !isShutDown, connectionSequences[host] == sequence,
              generation == machines.generation(for: host) else { return }
        clients.bind(connected.daemon, host: host, generation: generation)
        actions.hostConnected(host)
        chatMachineConnected(host, connected.chat)
        agentBrowsers.machineConnected(host, socketPath: socketPath)
        feeds.updateConnection(
            host: host, generation: generation, phase: .connected(daemon: connected.daemon, activitySource: connected.activitySource)
        )
        statsPoller.reconcile()
    }

    /// `host`'s daemon is up: its chat and unread counts bind to its client,
    /// and a synthetic resync through the chat relay (in order with the
    /// machine's live events) seeds its counts and reloads the shown thread
    /// if that thread lives there. The feed's own hello sends another; the
    /// seed and page tokens drop the stale answer.
    private func chatMachineConnected(_ host: LeoHostID, _ client: any LeoChatClient) {
        unread.bind(client, host: host)
        chat.bind(client, host: host)
        chatRelay.send(LeoChatFeedDelivery(host: host, signal: .resync))
    }

    /// `host`'s daemon is gone (connecting again, failed, or removed): its
    /// unread counts clear and a thread shown from it reads "isn't connected".
    private func chatMachineDisconnected(_ host: LeoHostID) {
        unread.unbind(host)
        chat.unbind(host)
    }

    /// The production `LeoRemoteDaemonFactory`: a socket client over the
    /// machine's tunnel, with SSE activity when its daemon has the socket
    /// event stream. `probe` detects the flavor.
    nonisolated static func tunnelledDaemon(probe: any LeoDaemonTransport) -> LeoRemoteDaemonFactory {
        { _, socketPath in
            let tunnelTransport = LeoTunnelSocketTransport(base: LeoUnixSocketTransport())
            let daemon = LeoSocketDaemonClient(socketPath: socketPath, transport: tunnelTransport)
            let flavor = await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath, transport: probe)
            let activity = flavor == .socketEvents
                ? LeoSidebarActivitySource(
                    events: { await LeoSocketActivityClient(socketPath: socketPath, transport: tunnelTransport).events() },
                    observedState: { try await LeoSocketActivityClient(socketPath: socketPath, transport: tunnelTransport).fetchState() }
                  )
                : LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
            let chat = LeoChatPaneModel.makeClient(socketPath: socketPath, transport: tunnelTransport)
            return LeoMachineDaemon(daemon: daemon, activitySource: activity, chat: chat)
        }
    }
}
