import AppKit
import Combine
import Foundation
import LeoKit

/// The plugin platform as the app wires it: the registry on disk, the manager,
/// the install flow and the updater, each with its real dependencies. The one
/// place production choices are made; everything it builds takes protocols.
@MainActor final class LeoPluginSystem {
    let store: LeoPluginStore
    let manager: LeoPluginManager
    let installFlow: LeoPluginInstallFlow
    let updater: LeoPluginUpdater
    let presenter: LeoPluginSheetPresenter
    /// The sidebar's plugin sections (slot 4).
    let sections: LeoPluginSidebarSections
    /// The command palette's plugin commands (slot 3).
    let commands: LeoPluginManagerCommandSource
    private let devWatcher: LeoPluginDevWatcher

    init(
        sidebar: LeoSidebarModel,
        clients: any LeoMachineClientResolving,
        machineFeeds: SpawnMachineFeeds,
        defaults: UserDefaults,
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        bundle: Bundle = .main,
        surfaces: any LeoPluginSlotSurface,
        presenter: LeoPluginSheetPresenter = LeoPluginSheetPresenter()
    ) {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        let root = LeoPluginRoot.url(applicationSupport: applicationSupport, isDebugBuild: isDebugBuild)
        let store = LeoPluginStore(root: root)
        let slots = LeoPluginSlotStore()
        let sources = LeoPluginAppSources(sidebar: sidebar, clients: clients, spawnMemory: SpawnMachineMemory(defaults: defaults))
        let templateFeed = LeoPluginSpawnTemplateFeed(
            list: { name in
                sources.host(forMachine: name).map(machineFeeds.templateList)
                    ?? Just(.failed("Unknown machine")).eraseToAnyPublisher()
            },
            reload: { name in sources.host(forMachine: name).map(machineFeeds.reload) })
        let executor = LeoPluginActionExecutor(
            daemons: sources, confirmer: LeoPluginSheetConfirmer(presenter: presenter, templates: templateFeed), effects: LeoPluginAppEffects(), slots: slots)
        let scheduler = LeoPluginDispatchTimerScheduler()
        let watcher = LeoPluginDevWatcher(source: LeoPluginDispatchFileEvents(), scheduler: scheduler)
        let helperPath = LeoPluginPosixLauncher.embedded(in: bundle).helperURL.path
        let manager = LeoPluginManager(LeoPluginManagerDependencies(
            store: store,
            bundledRoot: bundle.resourceURL?.appendingPathComponent("Plugins", isDirectory: true),
            hosts: LeoPluginProcessHostFactory(launcher: .embedded(in: bundle)),
            scheduler: scheduler,
            keychain: LeoPluginKeychainSelection.make(),
            agents: sources,
            actions: executor,
            trash: LeoPluginSystemTrash(),
            slots: slots,
            makeFetcher: { id, engine in LeoPluginFetcher(pluginID: id, engine: engine) },
            reapOrphans: { LeoPluginHostOrphanReaper.reap(helperPath: helperPath) },
            clock: { ProcessInfo.processInfo.systemUptime },
            devWatcher: watcher))
        watcher.onChange = { [weak manager] id in manager?.devPluginChanged(id) }
        let installer = LeoPluginGitInstaller(root: root, runner: LeoPluginProcessRunner(), idClaims: store)
        self.store = store
        self.manager = manager
        self.devWatcher = watcher
        self.presenter = presenter
        sections = LeoPluginSidebarSections(
            host: manager, preferences: { [unowned sidebar] in sidebar.preferences }, update: { [unowned sidebar] in sidebar.update($0) },
            changes: Publishers.Merge(manager.$plugins.map { _ in }, sidebar.$preferences.map { _ in }).eraseToAnyPublisher())
        commands = LeoPluginManagerCommandSource(host: manager, surface: surfaces)
        installFlow = LeoPluginInstallFlow(store: store, installer: installer, root: root)
        updater = LeoPluginUpdater(store: store, installer: installer, root: root)
    }

    /// Starts every plugin that should run. Call once at launch.
    func start() { manager.reload() }

    /// The sidebar's agents changed: tell the plugins that listen (debounced by the manager).
    func agentsDidChange() { manager.agentsDidChange() }

    func shutDown() { devWatcher.stopAll() }
}
