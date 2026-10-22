import Foundation
import LeoKit

/// A connected machine's daemon client and activity stream.
struct LeoMachineDaemon: Sendable {
    let daemon: any LeoDaemonClient
    let activitySource: LeoSidebarActivitySource
}

/// Builds a remote machine's `LeoMachineDaemon` for its forwarded socket.
typealias LeoRemoteDaemonFactory = @Sendable (_ host: LeoHostID, _ socketPath: String) async -> LeoMachineDaemon

/// Every machine connects on its own: its state transitions reach only its
/// own feed and client, and This Mac's never moves Chat anywhere.
extension LeoRuntime {
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
        gone.forEach { clients.unbind($0) }
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
            feeds.updateConnection(host: host, generation: generation, phase: .connecting)
        case .failed(let message, _):
            feeds.updateConnection(host: host, generation: generation, phase: .failed(message: message))
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
            ? LeoMachineDaemon(daemon: localDaemon, activitySource: localActivitySource)
            : await remoteDaemon(host, socketPath)
        guard !isShutDown, connectionSequences[host] == sequence,
              generation == machines.generation(for: host) else { return }
        clients.bind(connected.daemon, host: host, generation: generation)
        actions.hostConnected(host)
        feeds.updateConnection(
            host: host, generation: generation, phase: .connected(daemon: connected.daemon, activitySource: connected.activitySource)
        )
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
            return LeoMachineDaemon(daemon: daemon, activitySource: activity)
        }
    }
}
