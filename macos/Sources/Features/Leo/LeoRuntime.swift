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
    private let flavorState: LeoAPIFlavorState

    /// Pure composition helper: builds a socket daemon client configured for a
    /// known flavor (or a dynamic provider). Kept free of runtime/async state so
    /// it can be constructed and tested without spinning up detection.
    nonisolated static func makeClient(
        socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
        transport: any LeoDaemonTransport = LeoUnixSocketTransport(),
        flavor: LeoAPIFlavor = .legacy,
        flavorProvider: (@Sendable () async -> LeoAPIFlavor)? = nil
    ) -> LeoSocketDaemonClient {
        LeoSocketDaemonClient(socketPath: socketPath, transport: transport, flavor: flavor, flavorProvider: flavorProvider)
    }

    convenience init(defaults: UserDefaults = .ghostty) {
        let socketPath = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath
        let flavorState = LeoAPIFlavorState()
        let activity = LeoSidebarActivitySource(
            events: {
                AsyncStream { continuation in
                    let task = Task {
                        if await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath) == .hub {
                            let client = LeoHubActivityClient(socketPath: socketPath)
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
                if await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath) == .hub {
                    return try await LeoHubActivityClient(socketPath: socketPath).fetchState()
                }
                let config = await Task.detached { LeoObserveConfigLoader.load() }.value
                guard let config else { return [] }
                return try await LeoActivityClient(config: config).fetchState()
            }
        )
        let daemon = LeoRuntime.makeClient(socketPath: socketPath, flavorProvider: { [flavorState] in await flavorState.current })
        self.init(daemon: daemon, cli: LeoCLI(), activitySource: activity, defaults: defaults, flavorState: flavorState)
    }

    convenience init(daemon: any LeoDaemonClient, cli: LeoCLI, activity: LeoActivityClient, defaults: UserDefaults = .standard) {
        self.init(daemon: daemon, cli: cli, activitySource: LeoSidebarActivitySource(client: activity), defaults: defaults)
    }

    convenience init(daemon: any LeoDaemonClient, cli: LeoCLI, activitySource: LeoSidebarActivitySource, defaults: UserDefaults = .standard) {
        self.init(daemon: daemon, cli: cli, activitySource: activitySource, defaults: defaults, flavorState: LeoAPIFlavorState())
    }

    init(daemon: any LeoDaemonClient, cli: LeoCLI, activitySource: LeoSidebarActivitySource, defaults: UserDefaults = .standard, flavorState: LeoAPIFlavorState) {
        self.cli = cli
        self.defaults = defaults
        self.flavorState = flavorState
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
            daemon: daemon,
            defaults: defaults,
            // A successful (or failed) retry/connect applies to the feed
            // immediately -- restoring availability and refreshing, or
            // marking it failed -- instead of only updating the host picker
            // and waiting on an SSE host_state_changed event that a legacy
            // daemon (or a dropped SSE connection) may never deliver.
            hostStateTarget: { [weak feed] row in Task { await feed?.handleHostStateChanged(row) } },
            installTarget: { [weak feed] host in Task { await feed?.select(host) } }
        )
        actions = LeoAgentActions(daemon: daemon, cli: cli, model: model, hostSelection: hostSelection) { [weak feed] in
            Task { await feed?.refresh() }
        }
        Task { [feed, weak hostSelection] in
            await feed.observeHostStates { [weak hostSelection] row in hostSelection?.receive(row) }
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
        Task {
            let flavor = await LeoSocketDaemonClient.detectFlavor()
            await flavorState.update(flavor)
            await actions.hostSelection.start(flavor: flavor)
            await feed.start()
            await feed.setPolling(pollable)
        }
    }
    func shutdown() { Task { await feed.stop() } }
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
