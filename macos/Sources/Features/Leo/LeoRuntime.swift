import AppKit
import Foundation

@MainActor final class LeoRuntime {
    let model: LeoSidebarModel
    let registry: LeoWindowSessionRegistry
    let actions: LeoAgentActions
    private let feed: LeoSidebarFeed
    private let cli: LeoCLI
    private let defaults: UserDefaults
    private let attachCoordinator: LeoAttachCoordinator
    private let orphanStore: LeoTunnelOrphanStore

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
        let activity = LeoSidebarActivitySource(
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
        let daemon = LeoRuntime.makeClient(socketPath: socketPath)
        self.init(daemon: daemon, cli: LeoCLI(), activitySource: activity, defaults: defaults)
    }

    convenience init(daemon: any LeoDaemonClient, cli: LeoCLI, activity: LeoActivityClient, defaults: UserDefaults = .standard) {
        self.init(daemon: daemon, cli: cli, activitySource: LeoSidebarActivitySource(client: activity), defaults: defaults)
    }

    init(daemon: any LeoDaemonClient, cli: LeoCLI, activitySource: LeoSidebarActivitySource, defaults: UserDefaults = .standard) {
        self.cli = cli
        self.defaults = defaults
        let orphanStore = LeoTunnelOrphanStore(defaults: defaults)
        self.orphanStore = orphanStore
        let model = LeoSidebarModel()
        let registry = LeoWindowSessionRegistry()
        self.model = model
        self.registry = registry
        let host = GhosttyAttachTabHost(registry: registry)
        attachCoordinator = LeoAttachCoordinator(
            host: host,
            executable: {
                let override = defaults.string(forKey: "leo.executablePath")
                return try LeoCLI(executableOverride: override, runner: cli.runner).resolveExecutable()
            },
            report: { [weak model] error in
                let id = LeoAgentRow.ID(host: error.identity.host, name: error.identity.name)
                model?.setRowError(error.message, for: id)
            }
        )
        feed = LeoSidebarFeed(daemon: daemon, activity: activitySource) { [weak model] snapshot in
            model?.receive(snapshot)
        }
        let hostSelection = LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            orphanStore: orphanStore,
            installTarget: { [weak feed] host in Task { await feed?.select(host) } }
        )
        actions = LeoAgentActions(daemon: daemon, cli: cli, model: model, hostSelection: hostSelection) { [weak feed] in
            Task { await feed?.refresh() }
        }
        model.retryRequested = { [feed, hostSelection] in
            hostSelection.retry()
            Task { await feed.refresh() }
        }
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
            await actions.hostSelection.start(flavor: flavor)
            await feed.start()
            await feed.setPolling(pollable)
        }
    }
    func shutdown() {
        actions.hostSelection.shutdown()
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
}
