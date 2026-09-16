import AppKit
import Foundation

@MainActor final class LeoRuntime {
    let model: LeoSidebarModel
    let registry: LeoWindowSessionRegistry
    let actions: LeoAgentActions
    let hostSelection: LeoHostSelection
    private let feed: LeoSidebarFeed
    private let cli: LeoCLI
    private let defaults: UserDefaults
    private let attachCoordinator: LeoAttachCoordinator
    private let orphanStore: LeoTunnelOrphanStore
    private let localDaemon: any LeoDaemonClient
    private let localActivitySource: LeoSidebarActivitySource
    /// The highest `generation` any connection-state update has carried so
    /// far. `applyConnected`'s per-connection resource building (flavor
    /// detection, socket clients) is async; this guards against a stale
    /// build finishing after a newer selection has already superseded it.
    private var latestKnownGeneration = 0

    /// Pure composition helper: builds a socket daemon client bound to one
    /// socket path. Kept free of runtime/async state so it can be constructed
    /// and tested without spinning up detection.
    nonisolated static func makeClient(
        socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
        transport: any LeoDaemonTransport = LeoUnixSocketTransport()
    ) -> LeoSocketDaemonClient {
        LeoSocketDaemonClient(socketPath: socketPath, transport: transport)
    }

    convenience init(defaults: UserDefaults = .ghostty) {
        let socketPath = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath
        let activity = LeoRuntime.makeSocketOrLegacyActivitySource(socketPath: socketPath)
        let daemon = LeoRuntime.makeClient(socketPath: socketPath)
        self.init(daemon: daemon, cli: LeoCLI(), activitySource: activity, defaults: defaults)
    }

    convenience init(daemon: any LeoDaemonClient, cli: LeoCLI, activity: LeoActivityClient, defaults: UserDefaults = .standard) {
        self.init(daemon: daemon, cli: cli, activitySource: LeoSidebarActivitySource(client: activity), defaults: defaults)
    }

    init(daemon: any LeoDaemonClient, cli: LeoCLI, activitySource: LeoSidebarActivitySource, defaults: UserDefaults = .standard) {
        self.cli = cli
        self.defaults = defaults
        localDaemon = daemon
        localActivitySource = activitySource
        let orphanStore = LeoTunnelOrphanStore(defaults: defaults)
        self.orphanStore = orphanStore
        let model = LeoSidebarModel()
        let registry = LeoWindowSessionRegistry()
        self.model = model
        self.registry = registry
        let host = GhosttyAttachTabHost(registry: registry)
        weak var weakSelf: LeoRuntime?
        let hostSelection = LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            orphanStore: orphanStore,
            connectionTarget: { host, generation, state in
                weakSelf?.applyConnection(host: host, generation: generation, state: state)
            }
        )
        self.hostSelection = hostSelection
        attachCoordinator = LeoAttachCoordinator(
            host: host,
            executable: {
                let override = defaults.string(forKey: "leo.executablePath")
                return try LeoCLI(executableOverride: override, runner: cli.runner).resolveExecutable()
            },
            remoteCommandBuilder: { [weak hostSelection] identity in
                guard case .remote(let name) = identity.host,
                      let configuration = hostSelection?.hosts.first(where: { $0.name == name }) else {
                    throw LeoDaemonError.hostUnavailable("Remote host \(identity.host.displayName) is not configured")
                }
                return try LeoSSHCommand(configuration: configuration).attachShellCommand(agent: identity.name)
            },
            report: { [weak model] error in
                let id = LeoAgentRow.ID(host: error.identity.host, name: error.identity.name)
                model?.setRowError(error.message, for: id)
            }
        )
        feed = LeoSidebarFeed(daemon: daemon, activity: activitySource) { [weak model] snapshot in
            model?.receive(snapshot)
        }
        actions = LeoAgentActions(daemon: daemon, cli: cli, model: model, hostSelection: hostSelection) { [weak feed] in
            Task { await feed?.refresh() }
        }
        model.retryRequested = { [hostSelection] in hostSelection.retry() }
        registry.pollabilityChanged = { [feed] pollable in Task { await feed.setPolling(pollable) } }
        model.startDaemonRequested = { [weak self] in
            guard let controller = NSApp.keyWindow?.windowController as? TerminalController else { return }
            self?.startDaemon(in: controller)
        }
        model.sshRequested = { [weak self] target in
            guard let self, let controller = NSApp.keyWindow?.windowController as? TerminalController else { return }
            do {
                guard LeoCommandLauncher.openTab(in: controller, command: try LeoCommandLauncher.sshHintCommand(target: target)) else {
                    self.model.setPanelError("Unable to open a terminal tab")
                    return
                }
            } catch { self.model.setPanelError(error.localizedDescription) }
        }
        model.attachRequested = { [weak attachCoordinator, weak model] row, origin, disposition in
            model?.selection = row.id
            Task { await attachCoordinator?.attach(identity: row.identity, from: origin, disposition: disposition) }
        }

        // `hostSelection`'s `connectionTarget` (wired above) closes over
        // `weakSelf`, which can only be set once `self` is fully
        // initialized -- every LeoHostSelection state transition
        // (connecting/connected/failed), tagged with the generation it
        // belongs to, drives which connection the feed and agent actions
        // are bound to.
        weakSelf = self
    }

    func start() {
        let pollable = registry.hasPollableSidebar
        let orphanStore = orphanStore
        Task {
            // Must run before any tunnel this launch might start, so a
            // leftover record always describes a process untouched this run.
            await Task.detached {
                orphanStore.reapAtLaunch(inspector: leoTunnelRealInspector, signaller: leoTunnelRealSignaller)
            }.value
            let flavor = await LeoSocketDaemonClient.detectFlavor()
            await feed.start()
            await feed.setInitialPolling(pollable)
            await hostSelection.start(flavor: flavor)
        }
    }
    func shutdown() {
        hostSelection.shutdown()
        Task { await feed.stop() }
    }
    func makeWindowSession(for controller: TerminalController) -> LeoWindowSession {
        registry.makeSession(window: controller.window, controller: controller, defaults: defaults)
    }

    func makeWindowSession() -> LeoWindowSession {
        registry.makeSession(defaults: defaults)
    }

    func resolveExecutablePath() throws -> String {
        let override = defaults.string(forKey: "leo.executablePath")
        return try LeoCLI(executableOverride: override, runner: cli.runner).resolveExecutable()
    }

    /// Applies a `LeoHostSelection` connection-state transition to the feed
    /// (and, once connected, to agent actions). `.connecting`/`.failed`
    /// carry no async work of their own and are forwarded immediately;
    /// `.connected` needs to build the per-connection daemon/activity
    /// resources first (see `applyConnected`).
    private func applyConnection(host: LeoHostID, generation: Int, state: LeoHostConnectionState) {
        latestKnownGeneration = max(latestKnownGeneration, generation)
        switch state {
        case .connecting:
            Task { [weak feed] in await feed?.updateConnection(host: host, generation: generation, phase: .connecting) }
        case .failed(let message, _):
            Task { [weak feed] in await feed?.updateConnection(host: host, generation: generation, phase: .failed(message: message)) }
        case .connected(let socketPath):
            Task { [weak self] in await self?.applyConnected(host: host, generation: generation, socketPath: socketPath) }
        }
    }

    /// Builds the daemon client + activity source for `(host, socketPath)`
    /// -- reusing the precomputed local ones for `.local`, or a fresh
    /// per-socket client (with its own flavor detection) for a remote host
    /// -- and only then wires them into the feed and agent actions. Guarded
    /// against `latestKnownGeneration`: if a newer selection has already
    /// superseded this one by the time flavor detection (the only await in
    /// this path) completes, the stale result is discarded.
    private func applyConnected(host: LeoHostID, generation: Int, socketPath: String) async {
        let daemon: any LeoDaemonClient
        let activitySource: LeoSidebarActivitySource
        if host == .local {
            daemon = localDaemon
            activitySource = localActivitySource
        } else {
            daemon = LeoSocketDaemonClient(socketPath: socketPath)
            let remoteFlavor = await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath)
            activitySource = remoteFlavor == .socketEvents
                ? LeoSidebarActivitySource(
                    events: { await LeoSocketActivityClient(socketPath: socketPath).events() },
                    fetchState: { try await LeoSocketActivityClient(socketPath: socketPath).fetchState() }
                  )
                : LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        }
        guard generation == latestKnownGeneration else { return }
        actions.updateDaemon(daemon)
        await feed.updateConnection(host: host, generation: generation, phase: .connected(daemon: daemon, activitySource: activitySource))
    }

    private func startDaemon(in controller: TerminalController) {
        do {
            let command = try LeoCommandLauncher.startDaemonCommand(executablePath: resolveExecutablePath())
            guard LeoCommandLauncher.openTab(in: controller, command: command) else {
                model.setPanelError("Unable to open a terminal tab")
                return
            }
        } catch {
            model.setPanelError(error.localizedDescription)
        }
    }

    private nonisolated static func makeSocketOrLegacyActivitySource(socketPath: String) -> LeoSidebarActivitySource {
        LeoSidebarActivitySource(
            events: {
                AsyncStream { continuation in
                    let task = Task {
                        if await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath) == .socketEvents {
                            let client = LeoSocketActivityClient(socketPath: socketPath)
                            for await event in await client.events() { continuation.yield(event) }
                            continuation.finish()
                            return
                        }
                        let config = await Task.detached { LeoObserveConfigLoader.load() }.value
                        guard let config else { continuation.finish(); return }
                        let client = LeoActivityClient(config: config)
                        for await event in await client.events() {
                            guard !Task.isCancelled else { break }
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            },
            fetchState: {
                if await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath) == .socketEvents {
                    return try await LeoSocketActivityClient(socketPath: socketPath).fetchState()
                }
                let config = await Task.detached { LeoObserveConfigLoader.load() }.value
                guard let config else { return [] }
                return try await LeoActivityClient(config: config).fetchState()
            }
        )
    }
}
