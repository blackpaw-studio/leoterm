import Combine
import Foundation
import OSLog

/// Why a plugin is, or isn't, running.
public enum LeoPluginRunState: Equatable, Sendable {
    case running
    /// The user turned it off.
    case stoppedByUser
    /// Its manifest asks for more than the user approved (an app update, a
    /// dev edit). Nothing runs until they approve.
    case needsApproval(LeoPluginPermissionDiff)
    /// Crashed; the supervisor will restart it.
    case restarting(reason: String)
    /// Crash-disabled until the user re-enables it.
    case disabled(reason: String)
    /// Its folder or manifest can't be used.
    case refused(String)
}

/// A plugin as Settings and the slots list it.
public struct LeoPluginInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let source: LeoPluginSource
    public let isEnabled: Bool
    public let state: LeoPluginRunState
    public let approvedPermissions: LeoPluginPermissions
    public let manifest: LeoPluginManifest?
    public let hiddenSections: [String]
}

public enum LeoPluginManagerError: Error, Equatable, LocalizedError, Sendable {
    case unknownPlugin(String)
    case cannotUninstallBundled(String)

    public var errorDescription: String? {
        switch self {
        case .unknownPlugin(let id): "There is no plugin '\(id)'."
        case .cannotUninstallBundled: "Built-in plugins can be turned off but not removed."
        }
    }
}

/// Everything the manager is given. Nothing global: production wires real
/// processes and the Keychain, tests wire fakes.
public struct LeoPluginManagerDependencies {
    public let store: LeoPluginStore
    public let bundledRoot: URL?
    public let hosts: any LeoPluginHostMaking
    public let scheduler: any LeoPluginTimerScheduling
    public let keychain: any LeoPluginKeychain
    public let agents: any LeoPluginAgentSource
    public let actions: any LeoPluginActionRunning
    public let trash: any LeoPluginTrashing
    public let slots: LeoPluginSlotStore
    public let makeFetcher: @Sendable (_ pluginID: String, _ engine: LeoPluginPermissionEngine) -> any LeoPluginFetching
    /// Kills helpers a dead Leo left behind. Called once, before the first helper is spawned.
    public let reapOrphans: @MainActor () -> Void
    /// Monotonic seconds, for the crash supervisor.
    public let clock: @Sendable () -> TimeInterval
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (TimeInterval) async throws -> Void
    public let agentsDebounce: TimeInterval
    public let devWatcher: (any LeoPluginDevWatching)?

    public init(
        store: LeoPluginStore, bundledRoot: URL?, hosts: any LeoPluginHostMaking, scheduler: any LeoPluginTimerScheduling,
        keychain: any LeoPluginKeychain, agents: any LeoPluginAgentSource, actions: any LeoPluginActionRunning,
        trash: any LeoPluginTrashing, slots: LeoPluginSlotStore,
        makeFetcher: @escaping @Sendable (String, LeoPluginPermissionEngine) -> any LeoPluginFetching,
        reapOrphans: @escaping @MainActor () -> Void, clock: @escaping @Sendable () -> TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        agentsDebounce: TimeInterval = 0.5, devWatcher: (any LeoPluginDevWatching)? = nil
    ) {
        self.store = store
        self.bundledRoot = bundledRoot
        self.hosts = hosts
        self.scheduler = scheduler
        self.keychain = keychain
        self.agents = agents
        self.actions = actions
        self.trash = trash
        self.slots = slots
        self.makeFetcher = makeFetcher
        self.reapOrphans = reapOrphans
        self.clock = clock
        self.now = now
        self.sleep = sleep
        self.agentsDebounce = agentsDebounce
        self.devWatcher = devWatcher
    }
}

/// Owns every plugin's life: which are known, which run, and one host process
/// plus router per running plugin. Everything runs on the main actor, so a
/// plugin's requests, timers and replies are handled on one actor in order.
@MainActor public final class LeoPluginManager: ObservableObject {
    @Published public private(set) var plugins: [LeoPluginInfo] = []

    let deps: LeoPluginManagerDependencies
    var entries: [String: LeoPluginManagerEntry] = [:]
    private var hasReapedOrphans = false
    var agentsChangeTask: Task<Void, Never>?
    static let logger = LeoLog.logger(category: "leo.plugins")

    public var slots: LeoPluginSlotStore { deps.slots }

    public init(_ dependencies: LeoPluginManagerDependencies) {
        deps = dependencies
    }

    // MARK: Lifecycle

    /// Finds every plugin and starts the ones that should run. Call it at
    /// launch, and again after anything changes on disk or in the registry.
    /// Plugins in `restarting` are restarted even if nothing about them changed
    /// (a dev edit, an update).
    public func reload(restarting: Set<String> = []) {
        let registry = deps.store.registry
        registerBundled(registry)
        let current = deps.store.registry
        let found = LeoPluginDiscovery.discover(
            bundledRoot: deps.bundledRoot, installedRoot: deps.store.root, installed: installedSHAs(current),
            devFolders: current.devFolders)

        let ids = Set(current.records.map(\.id))
        for id in entries.keys where !ids.contains(id) { drop(id) }
        for record in current.records {
            apply(record, candidate: candidate(for: record, in: found), restart: restarting.contains(record.id))
        }
        publish()
        deps.devWatcher?.sync(devTargets(current, found))
    }

    /// A dev plugin's files changed on disk.
    public func devPluginChanged(_ id: String) {
        reload(restarting: [id])
    }

    public func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard deps.store.registry.record(for: id) != nil else { throw LeoPluginManagerError.unknownPlugin(id) }
        try deps.store.update { $0.setEnabled(id, enabled) }
        if enabled { entries[id]?.supervisor.reenable() }
        reload(restarting: enabled ? [id] : [])
    }

    /// The user approved what the plugin's manifest now asks for.
    public func approveCurrentPermissions(_ id: String) throws {
        guard let manifest = entries[id]?.manifest else { throw LeoPluginManagerError.unknownPlugin(id) }
        try deps.store.update { $0.approve(id, permissions: manifest.permissions) }
        reload(restarting: [id])
    }

    public func setSection(_ id: String, section: String, hidden: Bool) throws {
        try deps.store.update { $0.setSection(id, section: section, hidden: hidden) }
        publish()
    }

    /// Removes a plugin: stops it, moves its folder to the Trash, deletes its
    /// Keychain items and forgets it. A dev folder is the author's own and is
    /// left where it is. Bundled plugins can only be turned off.
    public func uninstall(_ id: String) throws {
        guard let record = deps.store.registry.record(for: id) else { throw LeoPluginManagerError.unknownPlugin(id) }
        if case .bundled = record.source { throw LeoPluginManagerError.cannotUninstallBundled(id) }
        drop(id)
        let secrets = try LeoPluginSecrets(pluginID: id, engine: LeoPluginPermissionEngine(permissions: .none), keychain: deps.keychain)
        try secrets.removeAll()
        if case .git = record.source {
            let folder = deps.store.root.appendingPathComponent(id)
            if FileManager.default.fileExists(atPath: folder.path) { try deps.trash.moveToTrash(folder) }
        }
        try deps.store.update { $0.remove(id) }
        reload()
    }

    // MARK: Private

    private func registerBundled(_ registry: LeoPluginRegistry) {
        guard let bundledRoot = deps.bundledRoot else { return }
        let bundled = LeoPluginDiscovery.discover(bundledRoot: bundledRoot, installedRoot: deps.store.root, installed: [:], devFolders: [])
        for manifest in bundled.plugins.compactMap(\.manifest) where registry.record(for: manifest.id) == nil {
            try? deps.store.update { $0.registerBundled(manifest) }
        }
    }

    private func installedSHAs(_ registry: LeoPluginRegistry) -> [String: String] {
        var result: [String: String] = [:]
        for record in registry.records {
            if case .git(_, _, let sha) = record.source { result[record.id] = sha }
        }
        return result
    }

    /// The folder a record points at, looked up by the record's own origin and
    /// path, not by manifest id: discovery keeps one winner per id, and a dev
    /// folder claiming an installed or bundled id would otherwise take that
    /// plugin's candidate away. The registry is the authority on what is what.
    private func candidate(for record: LeoPluginRecord, in found: LeoPluginDiscoveryResult) -> LeoPluginCandidate? {
        let all = found.plugins + found.shadowed
        switch record.source {
        case .bundled: return all.first { $0.origin == .bundled && $0.directory.lastPathComponent == record.id }
        case .git(_, _, let sha):
            return all.first { $0.origin == .installed(sha: sha) && $0.directory.deletingLastPathComponent().lastPathComponent == record.id }
        case .dev(let path): return all.first { $0.origin == .dev && $0.directory.path == URL(fileURLWithPath: path).path }
        }
    }

    private func devTargets(_ registry: LeoPluginRegistry, _ found: LeoPluginDiscoveryResult) -> [LeoPluginDevTarget] {
        registry.records.compactMap { record in
            guard case .dev(let path) = record.source else { return nil }
            let folder = URL(fileURLWithPath: path)
            var urls = [folder, folder.appendingPathComponent(LeoPluginGitInstaller.manifestFileName)]
            if let main = entries[record.id]?.manifest?.main {
                let file = folder.appendingPathComponent(main)
                urls += [file.deletingLastPathComponent(), file]
            }
            return LeoPluginDevTarget(id: record.id, urls: urls)
        }
    }

    /// Brings one plugin's runtime in line with its record and what is on disk.
    private func apply(_ record: LeoPluginRecord, candidate: LeoPluginCandidate?, restart: Bool) {
        let entry = entries[record.id] ?? LeoPluginManagerEntry(id: record.id)
        entries[record.id] = entry
        entry.record = record
        guard let candidate, let manifest = candidate.manifest else {
            stop(entry, state: .refused(candidate?.refusal ?? "its folder is missing"))
            return
        }
        if case .dev = record.source, manifest.id != record.id {
            stop(entry, state: .refused("its manifest id changed to '\(manifest.id)'; load the folder again"))
            return
        }
        let changed = entry.manifest != manifest || entry.directory != candidate.directory || entry.approved != record.approvedPermissions
        entry.manifest = manifest
        entry.directory = candidate.directory
        if entry.approved != record.approvedPermissions || entry.services == nil { entry.configureServices(record.approvedPermissions, deps: deps) }

        let diff = LeoPluginPermissionDiff(old: record.approvedPermissions, new: manifest.permissions)
        if !diff.isEmpty { return stop(entry, state: .needsApproval(diff)) }
        if !record.enabled { return stop(entry, state: .stoppedByUser) }
        if let reason = record.disabledReason { return stop(entry, state: .disabled(reason: reason)) }
        if entry.session != nil || entry.state.isRestarting {
            guard changed || restart else { return }
        }
        start(entry)
    }

    private func drop(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        deps.actions.cancelPending(pluginID: id)
        tearDown(entry)
        deps.slots.remove(pluginID: id)
    }

    // MARK: Sessions

    private func start(_ entry: LeoPluginManagerEntry) {
        tearDown(entry)
        guard let manifest = entry.manifest, let directory = entry.directory, let services = entry.services else { return }
        let source: String
        do {
            source = try LeoPluginBundleFile.readMain(manifest.main, in: directory)
        } catch let refusal as LeoPluginBundleFile.Refusal {
            return stop(entry, state: .refused("main file refused: \(refusal.message)"))
        } catch {
            return stop(entry, state: .refused("main file can't be read"))
        }
        if !hasReapedOrphans {
            hasReapedOrphans = true
            deps.reapOrphans()
        }
        let session = makeSession(for: entry, manifest: manifest, services: services)
        entry.session = session
        entry.state = .running
        deps.slots.reset(pluginID: entry.id)
        deps.slots.setStatus(pluginID: entry.id, .running)
        do {
            try session.host.start(source: source)
        } catch {
            return crashed(entry, token: session.token, reason: "couldn't start: \(error.localizedDescription)")
        }
        deliver(.activate(slot: nil), to: entry)
        for (slot, event) in entry.lastEvents {
            deps.slots.expect(pluginID: entry.id, slot: slot)
            deliver(event, to: entry)
        }
        publish()
    }

    private func makeSession(
        for entry: LeoPluginManagerEntry, manifest: LeoPluginManifest, services: LeoPluginManagerEntry.Services
    ) -> LeoPluginManagerEntry.Session {
        let token = UUID()
        let host = deps.hosts.makeHost()
        let id = entry.id
        let timers = LeoPluginTimers(scheduler: deps.scheduler) { [weak self] timerID in
            Task { @MainActor in
                guard let self, let entry = self.entries[id], entry.session?.token == token else { return }
                self.deliver(.timerFired(id: timerID), to: entry)
            }
        }
        let router = LeoPluginBridgeRouter(
            LeoPluginBridgeRouter.Dependencies(
                identity: LeoPluginIdentity(id: id, name: manifest.name), manifest: manifest,
                engine: services.engine, gate: services.gate, fetcher: services.fetcher, secrets: services.secrets, timers: timers,
                slots: deps.slots, actions: deps.actions, agents: { [agents = deps.agents] in agents.currentAgents() },
                now: deps.now,
                send: { [weak self] event in
                    guard let self, let entry = self.entries[id], entry.session?.token == token else { return }
                    self.deliver(event, to: entry)
                }))
        host.onRequest = { [weak self] request in
            MainActor.assumeIsolated {
                guard let self, let entry = self.entries[id], entry.session?.token == token else { return }
                entry.session?.router.handle(request)
            }
        }
        host.onTermination = { [weak self] termination in
            MainActor.assumeIsolated {
                guard let self, let entry = self.entries[id], entry.session?.token == token else { return }
                if case .crashed(let reason) = termination { self.crashed(entry, token: token, reason: reason) }
            }
        }
        return LeoPluginManagerEntry.Session(token: token, host: host, router: router, timers: timers)
    }

    private func crashed(_ entry: LeoPluginManagerEntry, token: UUID, reason: String) {
        guard entry.session?.token == token else { return }
        tearDown(entry)
        switch entry.supervisor.recordCrash(reason: reason, at: deps.clock()) {
        case .restart(let delay):
            entry.state = .restarting(reason: reason)
            deps.slots.setStatus(pluginID: entry.id, .failed(reason: "\(reason). Restarting in \(Int(delay)) s."))
            entry.restartTask = Task { [weak self, id = entry.id] in
                try? await self?.deps.sleep(delay)
                guard !Task.isCancelled, let self, let entry = self.entries[id], entry.state.isRestarting else { return }
                self.start(entry)
            }
        case .disable(let lastReason):
            let message = "Turned off after repeated crashes: \(lastReason)"
            try? deps.store.update { $0.setDisabled(entry.id, reason: message) }
            entry.state = .disabled(reason: message)
            deps.slots.setStatus(pluginID: entry.id, .disabled(reason: message))
        }
        publish()
    }

    /// Stops the session and parks the entry in a non-running state.
    private func stop(_ entry: LeoPluginManagerEntry, state: LeoPluginRunState) {
        deps.actions.cancelPending(pluginID: entry.id)
        tearDown(entry)
        entry.state = state
        deps.slots.setStatus(pluginID: entry.id, state.slotStatus)
    }

    private func tearDown(_ entry: LeoPluginManagerEntry) {
        entry.restartTask?.cancel()
        entry.restartTask = nil
        guard let session = entry.session else { return }
        entry.session = nil
        session.router.close()
        session.timers.stopAll()
        session.host.stop()
    }

    func deliver(_ event: LeoPluginEvent, to entry: LeoPluginManagerEntry) {
        guard let session = entry.session else { return }
        do { try session.host.deliver(event) } catch {
            Self.logger.debug("[\(entry.id, privacy: .public)] event not delivered: \(error.localizedDescription, privacy: .public)")
        }
    }

    func publish() {
        plugins = deps.store.registry.records.map { record in
            let entry = entries[record.id]
            return LeoPluginInfo(
                id: record.id, name: entry?.manifest?.name ?? record.name, version: entry?.manifest?.version ?? record.version,
                source: record.source, isEnabled: record.enabled, state: entry?.state ?? .refused("not loaded"),
                approvedPermissions: record.approvedPermissions, manifest: entry?.manifest, hiddenSections: record.hiddenSections)
        }
    }
}

extension LeoPluginRunState {
    var isRestarting: Bool {
        if case .restarting = self { return true }
        return false
    }

    var slotStatus: LeoPluginSlotStatus {
        switch self {
        case .running: .running
        case .restarting(let reason): .failed(reason: reason)
        case .stoppedByUser: .disabled(reason: "Turned off in Settings → Plugins.")
        case .needsApproval: .disabled(reason: "Asks for more permissions than you approved. Review it in Settings → Plugins.")
        case .disabled(let reason): .disabled(reason: reason)
        case .refused(let reason): .disabled(reason: "Can't run: \(reason)")
        }
    }
}
