import Foundation

@MainActor final class LeoRuntime {
    let model: LeoSidebarModel
    let registry: LeoWindowSessionRegistry
    private let feed: LeoSidebarFeed
    private let cli: LeoCLI
    private let defaults: UserDefaults

    init(daemon: any LeoDaemonClient, cli: LeoCLI, activity: LeoActivityClient, defaults: UserDefaults = .standard) {
        self.cli = cli
        self.defaults = defaults
        model = LeoSidebarModel()
        registry = LeoWindowSessionRegistry()
        feed = LeoSidebarFeed(daemon: daemon, activity: LeoSidebarActivitySource(client: activity)) { [weak model] snapshot in
            model?.receive(snapshot)
        }
        model.retryRequested = { [feed] in Task { await feed.refresh() } }
        registry.pollabilityChanged = { [feed] pollable in Task { await feed.setPolling(pollable) } }
    }

    func start() {
        let pollable = registry.hasPollableSidebar
        Task {
            await feed.start()
            await feed.setPolling(pollable)
        }
    }
    func shutdown() { Task { await feed.stop() } }
    func makeWindowSession() -> LeoWindowSession { registry.makeSession(defaults: defaults) }
}
