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

    convenience init(defaults: UserDefaults = .ghostty) {
        let activity = LeoSidebarActivitySource(
            events: {
                AsyncStream { continuation in
                    let task = Task {
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
                let config = await Task.detached { LeoObserveConfigLoader.load() }.value
                guard let config else { return [] }
                return try await LeoActivityClient(config: config).fetchState()
            }
        )
        self.init(daemon: LeoSocketDaemonClient(), cli: LeoCLI(), activitySource: activity, defaults: defaults)
    }

    convenience init(daemon: any LeoDaemonClient, cli: LeoCLI, activity: LeoActivityClient, defaults: UserDefaults = .standard) {
        self.init(daemon: daemon, cli: cli, activitySource: LeoSidebarActivitySource(client: activity), defaults: defaults)
    }

    init(daemon: any LeoDaemonClient, cli: LeoCLI, activitySource: LeoSidebarActivitySource, defaults: UserDefaults = .standard) {
        self.cli = cli
        self.defaults = defaults
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
        actions = LeoAgentActions(daemon: daemon, cli: cli, model: model) { [weak feed] in
            Task { await feed?.refresh() }
        }
        model.retryRequested = { [feed] in Task { await feed.refresh() } }
        registry.pollabilityChanged = { [feed] pollable in Task { await feed.setPolling(pollable) } }
        model.startDaemonRequested = { [weak self] in
            guard let controller = NSApp.keyWindow?.windowController as? TerminalController else { return }
            self?.startDaemon(in: controller)
        }
        model.attachRequested = { [weak attachCoordinator] row, origin, disposition in
            model.selection = row.id
            Task { await attachCoordinator?.attach(identity: row.identity, from: origin, disposition: disposition) }
        }
    }

    func start() {
        let pollable = registry.hasPollableSidebar
        Task {
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
            LeoCommandLauncher.openTab(in: controller, command: command)
        } catch {
            NSSound.beep()
        }
    }
}
