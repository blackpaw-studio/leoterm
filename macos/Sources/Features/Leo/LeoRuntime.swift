import AppKit
import Foundation
import GhosttyKit
import OSLog

@MainActor final class LeoRuntime {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let model: LeoSidebarModel
    let registry: LeoWindowSessionRegistry
    let actions: LeoAgentActions
    let hostSelection: LeoHostSelection
    /// Agents ▸ Agent Notifications… policy for background transitions.
    let attentionNotifications: LeoAttentionController
    let feed: LeoSidebarFeed
    /// Every close of a tab, window or the app with unsaved editor edits
    /// asks through this first (B-004).
    let unsavedEditors = LeoUnsavedEditorsGate()
    /// The start screen's shortcut tooltips, read off the live menu each
    /// time AppDelegate syncs its shortcuts from the config (B-080).
    let shortcutHints = LeoShortcutHints()
    /// Checks surfaced-file opens the user asks for (B-013).
    private(set) var surfacedFileOpener: LeoSurfacedFileOpener!
    /// Focus identity into `feed`, delivered in order (see
    /// `focusedAgentChanged`).
    let focusedAgentRelay: LeoOrderedRelay<LeoAgentRow.ID?>
    private let cli: LeoCLI
    private let defaults: UserDefaults
    let attachCoordinator: LeoAttachCoordinator
    /// The Ghostty side of attaching, for what only it can answer (hidden
    /// shells' processes, B-057).
    private let attachHost: GhosttyAttachContentHost
    let newSurfaceRouter: LeoNewSurfaceRouter
    private let picker: LeoWindowPickerRouter
    private let requestConfigStore: LeoRequestConfigStore
    private let orphanStore: LeoTunnelOrphanStore
    private let localDaemon: any LeoDaemonClient
    private let localActivitySource: LeoSidebarActivitySource
    private let hostConnectionTransport: any LeoDaemonTransport
    /// Bumped on EVERY `connectionTarget` transition (connecting/connected/
    /// failed) AND on `shutdown()` -- never just when `generation` changes.
    /// `LeoHostSelection.generation` alone is not enough to guard
    /// `applyConnected`'s async resource build: a `.failed` published for
    /// the SAME generation as a `.connecting` that's still mid-flavor-
    /// detection would otherwise leave the stale `.connected` build free to
    /// install over it once its `await` finally resolves.
    private var connectionSequence = 0
    /// Runs the one liveness check per wake (D-061); removed with `self`.
    private var wakeObservation: LeoNotificationObservation?
    #if DEBUG
    private let openFileFixture = LeoOpenFileFixture()
    private let surfaceFixture = LeoSurfaceFixtureInjector()
    private var forcedDisconnect: AnyObject?
    #endif

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
        var activity = LeoRuntime.makeSocketOrLegacyActivitySource(socketPath: socketPath)
        #if DEBUG
        if let overlay = LeoAttentionFixture.load() { activity = LeoAttentionFixture.wrap(activity, overlay: overlay) }
        #endif
        let daemon = LeoRuntime.makeClient(socketPath: socketPath)
        self.init(
            daemon: daemon, cli: LeoCLI(runner: LeoProcessRunner()), activitySource: activity, defaults: defaults,
            templateFetchRunner: LeoProcessRunner()
        )
    }

    convenience init(
        daemon: any LeoDaemonClient, cli: LeoCLI, activity: LeoActivityClient, defaults: UserDefaults = .standard,
        templateFetchRunner: any LeoProcessRunning
    ) {
        self.init(
            daemon: daemon, cli: cli, activitySource: LeoSidebarActivitySource(client: activity), defaults: defaults,
            templateFetchRunner: templateFetchRunner
        )
    }

    /// `templateFetchRunner` runs a remote host's one-off
    /// `ssh … leo template list --json` (B-061). Deliberately no default:
    /// every caller but the app's own `init(defaults:)` is a test, and a
    /// test that forgot it would ssh into a real host on selecting it.
    init(
        daemon: any LeoDaemonClient, cli: LeoCLI, activitySource: LeoSidebarActivitySource, defaults: UserDefaults = .standard,
        templateFetchRunner: any LeoProcessRunning,
        hostConnectionTransport: any LeoDaemonTransport = LeoUnixSocketTransport(),
        hostSelectionRunner: any LeoProcessRunning = LeoProcessRunner(),
        hostSelectionSSHExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        hostSelectionLegacySocketDirectory: URL = LeoTunnelOrphanStore.defaultLegacySocketDirectory,
        hostSelectionControlSocketDirectory: URL? = LeoControlSocketDirectory.default,
        notificationCenter: any LeoNotificationPosting = LeoUserNotificationCenter(),
        focusedAgentSink: (@Sendable (LeoAgentRow.ID?) async -> Void)? = nil,
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.cli = cli
        self.defaults = defaults
        localDaemon = daemon
        localActivitySource = activitySource
        self.hostConnectionTransport = hostConnectionTransport
        let orphanStore = LeoTunnelOrphanStore(defaults: defaults, legacySocketDirectory: hostSelectionLegacySocketDirectory)
        self.orphanStore = orphanStore
        let model = LeoSidebarModel(
            preferencesStore: LeoUserDefaultsSidebarPreferencesStore(defaults: defaults),
            surfacedSeenStore: LeoUserDefaultsSurfacedFileSeenStore(defaults: defaults)
        )
        let registry = LeoWindowSessionRegistry()
        self.model = model
        self.registry = registry
        weak var weakSelf: LeoRuntime?
        attentionNotifications = LeoAttentionController(
            center: notificationCenter, defaults: defaults, currentHost: { weakSelf?.hostSelection.selected },
            showDeniedInstructions: LeoRuntime.presentNotificationsDeniedInstructions
        )
        let requestConfigStore = LeoRequestConfigStore()
        self.requestConfigStore = requestConfigStore
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: requestConfigStore)
        attachHost = host
        let hostSelection = LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            runner: hostSelectionRunner,
            sshExecutable: hostSelectionSSHExecutable,
            transport: hostConnectionTransport,
            orphanStore: orphanStore,
            legacySocketDirectory: hostSelectionLegacySocketDirectory,
            controlSocketDirectory: hostSelectionControlSocketDirectory,
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
            },
            focusedIdentityChanged: { identity in weakSelf?.focusedAgentChanged(identity) },
            linkStateChanged: { [weak model] links in model?.receiveAttachLinks(links) }
        )
        let pickerRouter = LeoWindowPickerRouter()
        let router = LeoNewSurfaceRouter(
            attach: { [weak attachCoordinator] identity, request, placement in
                guard let attachCoordinator else {
                    return .failure(.init(identity: identity, kind: .openFailed("Leo runtime is unavailable")))
                }
                return await attachCoordinator.attach(identity: identity, request: request, placement: placement).map { _ in () }
            },
            openPlainShell: { [weak attachCoordinator] request in
                guard let attachCoordinator else {
                    return .failure(.init(
                        identity: LeoAgentIdentity(host: .local, name: ""),
                        kind: .openFailed("Leo runtime is unavailable")
                    ))
                }
                return await attachCoordinator.openPlainShell(request: request).map { _ in () }
            },
            presentSpawn: { [weak pickerRouter] request, complete in
                guard let pickerRouter else {
                    complete(nil)
                    return
                }
                pickerRouter.presentSpawn(for: request, completion: complete)
            },
            isRequestValid: { [weak registry] request in
                guard let controller = registry?.controller(for: request.origin) else { return false }
                if case .placeholder(let surfaceID) = request.disposition {
                    return if let surfaceID {
                        controller.leoSession?.placeholderSurfaceIDs.contains(surfaceID) == true
                    } else {
                        controller.surfaceTree.isEmpty
                    }
                }
                return true
            },
            onFailure: { [weak model, weak pickerRouter] request, error in
                model?.setPanelError(error.message)
                pickerRouter?.reportFailure(error, for: request)
            },
            onRequestEnded: { [weak requestConfigStore, weak pickerRouter] request in
                requestConfigStore?.drop(for: request.id)
                pickerRouter?.requestEnded(request)
            }
        )
        self.newSurfaceRouter = router
        self.picker = pickerRouter
        // A window's requests must not outlive its session: once the
        // session unregisters (window closed), any request still pending
        // for it can never be validly resolved (no controller to attach
        // into). This is the fallback path -- `report()` only runs the next
        // time *some* session's state changes or a new one is made, which
        // may be a while (or never, for a single-window quit). The prompt
        // path is `LeoWindowSession.onWindowWillClose`, wired in
        // `makeWindowSession(for:)` to call this same teardown immediately.
        // Both call `router.invalidate`/`pickerRouter.unregister`/
        // `attachCoordinator.windowClosed`, which are idempotent, so running
        // it twice for the same window is harmless.
        registry.onUnregistered = { [weak router, weak pickerRouter, weak attachCoordinator] windowID in
            router?.invalidate(origin: windowID)
            pickerRouter?.unregister(origin: windowID)
            attachCoordinator?.windowClosed(windowID)
        }

        // `actions` doesn't exist yet at the point `feed` is constructed
        // (its `refresh` closure below needs `feed`), so `feed`'s
        // manual-refresh callback is wired through this box instead of
        // capturing `actions` directly -- filled in immediately after
        // `actions` is created.
        // Captured strongly by `feed`'s closure below (kept alive exactly as
        // long as `feed` is), while the box itself only holds `actions`
        // weakly -- so this cannot create a `feed` <-> `actions` retain
        // cycle even though `actions`' own `refresh` closure also captures
        // `feed` (weakly, see below).
        let actionsBox = LeoAgentActionsBox()
        feed = LeoSidebarFeed(
            daemon: daemon, activity: activitySource,
            onManualRefresh: { [actionsBox] in actionsBox.actions?.invalidateTemplateCache() },
            onAttentionTransitions: { transitions in weakSelf?.attentionTransitionsCommitted(transitions) },
            sink: { [weak model] snapshot in
                model?.receive(snapshot)
                weakSelf?.snapshotLanded(snapshot)
            }
        )
        focusedAgentRelay = LeoOrderedRelay(sink: focusedAgentSink ?? { [weak feed] id in await feed?.setFocusedAgent(id) })
        actions = LeoAgentActions(
            daemon: daemon, cli: cli, model: model, hostSelection: hostSelection, processRunner: templateFetchRunner
        ) { [weak feed] in
            Task { await feed?.refresh() }
        }
        actionsBox.actions = actions
        model.startRequested = { [weak actions] row, completion in actions?.start(row, completion: completion) }
        model.retryRequested = { [hostSelection] in hostSelection.retry() }
        registry.pollabilityChanged = { [feed] pollable in Task { await feed.setPolling(pollable) } }
        model.startDaemonRequested = { [weak self] in
            guard let controller = NSApp.keyWindow?.windowController as? TerminalController else { return }
            self?.startDaemon(in: controller)
        }
        model.sshRequested = { [weak self] target in
            guard let self, let controller = NSApp.keyWindow?.windowController as? TerminalController else { return }
            do {
                guard LeoCommandLauncher.openWindow(in: controller, command: try LeoCommandLauncher.sshHintCommand(target: target)) else {
                    self.model.setPanelError("Unable to open a terminal window")
                    return
                }
            } catch { self.model.setPanelError(error.localizedDescription) }
        }
        model.attachRequested = { [weak attachCoordinator, weak model] row, origin, disposition in
            model?.selection = row.id
            Task { await attachCoordinator?.attach(identity: row.identity, from: origin, disposition: disposition) }
        }
        model.focusExistingRequested = { [weak attachCoordinator] row, origin in
            attachCoordinator?.focusExisting(row.identity, from: origin)
        }
        model.surfacedFileOpenRequested = { file, row, stillWanted in weakSelf?.openSurfacedFile(file, for: row, stillWanted: stillWanted) }
        model.latestFocusReport = { [weak attachCoordinator] in attachCoordinator?.latestFocusReport ?? 0 }

        // `hostSelection`'s `connectionTarget` (wired above) closes over
        // `weakSelf`, which can only be set once `self` is fully
        // initialized -- every LeoHostSelection state transition
        // (connecting/connected/failed), tagged with the generation it
        // belongs to, drives which connection the feed and agent actions
        // are bound to.
        weakSelf = self
        surfacedFileOpener = LeoSurfacedFileOpener { [weak model] file, host in model?.markSurfacedFileSeen(file, host: host) }

        // One immediate liveness check per wake, never repeated: a tunnel
        // or socket that died in sleep shows as disconnected (D-061).
        wakeObservation = LeoNotificationObservation(center: wakeNotifications, name: NSWorkspace.didWakeNotification) { [weak feed] in
            Task { await feed?.checkLiveness() }
        }
        #if DEBUG
        if let reason = LeoForcedDisconnectFixture.reason() {
            forcedDisconnect = LeoForcedDisconnectFixture.arm(model: model, reason: reason) { [weak feed] reason in
                Task { await feed?.disconnect(reason: reason) }
            }
        }
        #endif
    }

    /// Every snapshot the model receives; DEBUG fixtures hook in here.
    private func snapshotLanded(_ snapshot: LeoSidebarSnapshot) {
        #if DEBUG
        surfaceFixture.snapshotLanded(snapshot) { [feed] files in
            Task { for file in files { await feed.receive(.fileSurfaced(seq: nil, file: file)) } }
        }
        #endif
    }

    func start() {
        Self.logger.log("start() called")
        let pollable = registry.hasPollableSidebar
        let orphanStore = orphanStore
        Task {
            // Must run before any tunnel this launch might start, so a
            // leftover record always describes a process untouched this run.
            await Task.detached {
                orphanStore.reapAtLaunch(inspector: leoTunnelRealInspector, signaller: leoTunnelRealSignaller)
            }.value
            let flavor = await LeoSocketDaemonClient.detectFlavor()
            Self.logger.log("detected flavor=\(String(describing: flavor), privacy: .public) connectionSequence=\(self.connectionSequence)")
            await feed.start()
            await feed.setInitialPolling(pollable)
            await hostSelection.start(flavor: flavor)
            Self.logger.log("hostSelection.start(flavor:) returned")
        }
    }
    func shutdown() {
        connectionSequence += 1
        hostSelection.shutdown()
        Task { await feed.stop() }
    }
    func makeWindowSession(for controller: TerminalController) -> LeoWindowSession {
        let session = registry.makeSession(
            window: controller.window, controller: controller, defaults: defaults,
            makeFileAccess: { [weak hostSelection] host in
                guard let hostSelection else { throw LeoFileAccessError.unavailable(reason: "Leo is shutting down") }
                let access = try hostSelection.makeFileAccess(for: host)
                #if DEBUG
                return LeoSlowSaveFixture.wrapIfSet(access)
                #else
                return access
                #endif
            }
        )
        // Captures `sessionID` (a value), not `session` itself -- `session`
        // owns this closure, so capturing `session` here would be a
        // reference cycle (session -> closure -> session) that keeps the
        // window session, and everything it holds, alive forever.
        let sessionID = session.id
        session.openPicker = { [weak self] surfaceID in
            guard let self else { return }
            self.openPicker(windowID: sessionID, surfaceID: surfaceID)
        }
        session.onWindowWillClose = { [weak self] in self?.teardownWindow(sessionID) }
        wireTerminals(session.terminals, window: sessionID)
        if let window = controller.window {
            let presentation = LeoPickerPresentation(
                window: window,
                router: newSurfaceRouter,
                sidebar: model,
                hostSelection: hostSelection,
                actions: actions,
                setPickerPresented: { [weak session] presented in session?.setPickerPresented(presented) }
            )
            picker.register(presentation, for: sessionID)
        }
        #if DEBUG
        openFileFixture.windowCameUp { [weak self, weak session, weak controller] path in
            // Once the controller has finished setting the window up.
            Task { @MainActor in
                guard let self, let session, let controller else { return }
                await self.openFixtureFile(path, in: session) { LeoEditorAlerts.presentError($0, on: controller.window) }
            }
        }
        #endif
        return session
    }

    /// B-057: a window's terminal rows show, close and count their hidden
    /// shells through the coordinator and host.
    private func wireTerminals(_ terminals: LeoWindowTerminals, window: LeoWindowID) {
        terminals.showRequested = { [weak attachCoordinator] id in
            Task { await attachCoordinator?.showTerminal(AttachmentHandle(surfaceID: id, windowID: window)) }
        }
        terminals.closeRequested = { [weak attachCoordinator] id in
            attachCoordinator?.closeTerminal(AttachmentHandle(surfaceID: id, windowID: window))
        }
        terminals.hasBusyHiddenShell = { [weak attachHost] in attachHost?.hiddenTerminalsNeedConfirmQuit(in: window) ?? false }
        wireTerminalMenu(terminals, window: window)
    }

    /// B-177: a terminal row's context menu. Split shows the row, then asks
    /// for the split ⌘D would make beside its shell (inheriting its
    /// working directory); Rename… and Close act on the shell, shown or
    /// hidden.
    private func wireTerminalMenu(_ terminals: LeoWindowTerminals, window: LeoWindowID) {
        let handle: (UUID) -> AttachmentHandle = { AttachmentHandle(surfaceID: $0, windowID: window) }
        terminals.renameRequested = { [weak attachHost] in attachHost?.renameTerminal(handle($0), to: $1) }
        terminals.liveTitle = { [weak attachHost] in attachHost?.liveTitle(of: handle($0)) }
        terminals.closeFromMenuRequested = { [weak attachHost] id in
            Task { await attachHost?.closeTerminalFromMenu(handle(id)) }
        }
        terminals.splitRequested = { [weak self] id, direction in
            Task { [weak self] in
                guard let self else { return }
                await attachCoordinator.splitTerminal(handle(id), direction: direction) { request in
                    route(request, inheritedConfig: attachHost.splitConfiguration(for: handle(id)))
                }
            }
        }
    }

    /// B-057: ⌘T and File ▸ New Terminal. A new shell row in `origin`,
    /// shown in its content area (filling a start screen) and selected.
    /// `inheritedConfig` is the triggering terminal's, as for any new
    /// surface (see `routeNewSurface`).
    func newTerminal(origin: LeoWindowID, inheritedConfig: Ghostty.SurfaceConfiguration? = nil) {
        let request = LeoSurfaceRequest(origin: origin, disposition: .content)
        requestConfigStore.set(inheritedConfig, for: request.id)
        Self.logger.log("newTerminal origin=\(origin.rawValue.uuidString, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            let result = await attachCoordinator.openPlainShell(request: request)
            requestConfigStore.drop(for: request.id)
            if case .failure(let error) = result, !error.isCancellation { model.setPanelError(error.message) }
        }
    }

    func makeWindowSession() -> LeoWindowSession {
        registry.makeSession(defaults: defaults)
    }

    /// Tears down everything scoped to `windowID`: any pending new-surface
    /// request, that window's palette presentation (panel, model,
    /// subscriptions) and its attach bookkeeping. Idempotent -- safe to call from both
    /// `LeoWindowSession.onWindowWillClose` (prompt path) and
    /// `registry.onUnregistered` (fallback reconciliation), which may both
    /// fire for the same window.
    private func teardownWindow(_ windowID: LeoWindowID) {
        newSurfaceRouter.invalidate(origin: windowID)
        picker.unregister(origin: windowID)
        attachCoordinator.windowClosed(windowID)
    }

    /// Begins a new-surface gesture (Cmd+T, Cmd+D, Cmd+N, launch, or the
    /// placeholder's "pick an agent" button) for `origin` and immediately
    /// hands it to the picker. `sourceSurface` is required for `.split` and
    /// ignored otherwise (see `LeoSurfaceRequest`). `inheritedConfig` is the
    /// `Ghostty.SurfaceConfiguration` the triggering gesture carried (e.g.
    /// the focused surface's working directory) -- stashed in
    /// `requestConfigStore` keyed by the request's id, since
    /// `LeoSurfaceRequest` itself stays a pure value type with no AppKit
    /// dependency. `GhosttyAttachContentHost` consumes it when it actually
    /// creates the destination surface.
    func routeNewSurface(
        _ disposition: LeoSurfaceDisposition,
        origin: LeoWindowID,
        sourceSurface: UUID? = nil,
        inheritedConfig: Ghostty.SurfaceConfiguration? = nil
    ) {
        route(LeoSurfaceRequest(origin: origin, disposition: disposition, splitSourceSurface: sourceSurface), inheritedConfig: inheritedConfig)
    }

    /// `routeNewSurface` for a request already made (B-177's row-menu split).
    private func route(_ request: LeoSurfaceRequest, inheritedConfig: Ghostty.SurfaceConfiguration?) {
        Self.logger.log("routeNewSurface disposition=\(String(describing: request.disposition), privacy: .public) origin=\(request.origin.rawValue.uuidString, privacy: .public)")
        requestConfigStore.set(inheritedConfig, for: request.id)
        newSurfaceRouter.begin(request)
        picker.present(request: request)
    }

    func openPicker(windowID: LeoWindowID, surfaceID: UUID?) {
        routeNewSurface(.placeholder(surfaceID: surfaceID), origin: windowID)
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
        connectionSequence += 1
        let mySequence = connectionSequence
        switch state {
        case .connecting:
            Task { [weak feed] in await feed?.updateConnection(host: host, generation: generation, phase: .connecting) }
        case .failed(let message, _):
            Task { [weak feed] in await feed?.updateConnection(host: host, generation: generation, phase: .failed(message: message)) }
        case .connected(let socketPath):
            Task { [weak self] in await self?.applyConnected(host: host, generation: generation, socketPath: socketPath, sequence: mySequence) }
        }
    }

    /// Builds the daemon client + activity source for `(host, socketPath)`
    /// -- reusing the precomputed local ones for `.local`, or a fresh
    /// per-socket client (with its own flavor detection) for a remote host
    /// -- and only then wires them into the feed and agent actions. Guarded
    /// against `connectionSequence`, captured as `sequence` BEFORE the only
    /// `await` in this path (flavor detection): if ANY newer transition
    /// (connecting, connected, or failed -- not just a generation change)
    /// has since been observed, this stale result is discarded rather than
    /// installed over whatever's current now.
    private func applyConnected(host: LeoHostID, generation: Int, socketPath: String, sequence: Int) async {
        let daemon: any LeoDaemonClient
        let activitySource: LeoSidebarActivitySource
        if host == .local {
            daemon = localDaemon
            activitySource = localActivitySource
        } else {
            let tunnelTransport = LeoTunnelSocketTransport(base: LeoUnixSocketTransport())
            daemon = LeoSocketDaemonClient(socketPath: socketPath, transport: tunnelTransport)
            let remoteFlavor = await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath, transport: hostConnectionTransport)
            activitySource = remoteFlavor == .socketEvents
                ? LeoSidebarActivitySource(
                    events: { await LeoSocketActivityClient(socketPath: socketPath, transport: tunnelTransport).events() },
                    fetchState: { try await LeoSocketActivityClient(socketPath: socketPath, transport: tunnelTransport).fetchState() }
                  )
                : LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        }
        guard sequence == connectionSequence else { return }
        actions.updateDaemon(daemon, host: host)
        await feed.updateConnection(host: host, generation: generation, phase: .connected(daemon: daemon, activitySource: activitySource))
    }

    private func startDaemon(in controller: TerminalController) {
        do {
            let command = try LeoCommandLauncher.startDaemonCommand(executablePath: resolveExecutablePath())
            guard LeoCommandLauncher.openWindow(in: controller, command: command) else {
                model.setPanelError("Unable to open a terminal window")
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

/// Breaks the `feed` <-> `actions` construction cycle in `LeoRuntime.init`:
/// `feed`'s list-refresh callback needs to reach `actions`, but `actions`
/// isn't constructed until after `feed` (its own `refresh` closure needs
/// `feed`). Held weakly by the callback and filled in once, immediately
/// after `actions` exists.
@MainActor private final class LeoAgentActionsBox: @unchecked Sendable {
    weak var actions: LeoAgentActions?
}
