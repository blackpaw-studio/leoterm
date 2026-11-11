import Foundation

/// The manager's working state for one plugin. Main-actor only, by way of
/// the manager that owns it.
@MainActor final class LeoPluginManagerEntry {
    struct Session {
        let token: UUID
        let host: any LeoPluginHosting
        let router: LeoPluginBridgeRouter
        let timers: LeoPluginTimers
    }

    let id: String
    var record: LeoPluginRecord?
    var manifest: LeoPluginManifest?
    var directory: URL?
    var approved: LeoPluginPermissions?
    var state: LeoPluginRunState = .stoppedByUser
    var supervisor = LeoPluginSupervisor()
    var session: Session?
    var restartTask: Task<Void, Never>?
    /// Whether any of the plugin's slots is on screen. It outlives a session:
    /// the slots don't re-report after a restart, a disable/enable or an
    /// approval reload, so each new session is seeded from this.
    var isSlotVisible = false
    /// The event that last opened each slot, re-sent after a restart or a Retry.
    var lastEvents: [LeoPluginSlotID: LeoPluginEvent] = [:]
    /// Commands (the bundle load, then each delivered event) the helper hasn't
    /// reported `done` for yet.
    var outstandingCommands = 0
    /// Palette slots whose `command` event was delivered and not yet settled.
    var watchedCommandSlots: Set<LeoPluginSlotID> = []

    /// Per-plugin services that outlive a host restart: the rate limit and the
    /// gesture ledger must not reset just because the helper crashed.
    struct Services {
        let engine: LeoPluginPermissionEngine
        let gate: LeoPluginActionGate
        let fetcher: any LeoPluginFetching
        let secrets: LeoPluginSecrets?
    }

    private(set) var services: Services?
    /// The gate for direct, renderer-originated actions.
    var gate: LeoPluginActionGate? { services?.gate }

    init(id: String) { self.id = id }

    func configureServices(_ permissions: LeoPluginPermissions, deps: LeoPluginManagerDependencies) {
        approved = permissions
        let engine = LeoPluginPermissionEngine(permissions: permissions)
        services = Services(
            engine: engine, gate: LeoPluginActionGate(grants: permissions, now: deps.now),
            fetcher: deps.makeFetcher(id, engine), secrets: try? LeoPluginSecrets(pluginID: id, engine: engine, keychain: deps.keychain))
    }
}
