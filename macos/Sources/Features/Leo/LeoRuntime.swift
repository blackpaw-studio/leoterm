import AppKit
import Combine
import Foundation
import GhosttyKit
import OSLog
import LeoKit

@MainActor final class LeoRuntime {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let model: LeoSidebarModel
    let registry: LeoWindowSessionRegistry
    let actions: LeoAgentActions
    /// The prompt box and Interrupt / Compact / Clear (B-262), each call
    /// on the row's own machine's daemon, like `actions`.
    let control: LeoAgentControlModel
    /// Leo Chat for the selected agent: This Mac's daemon only, never
    /// rebound; fed This Mac's `chat.*` events in stream order by `chatRelay`.
    let chat: LeoChatPaneModel
    /// Unread agent messages per This Mac agent, behind the sidebar and
    /// Chat-switch badges; fed by `chatRelay` before `chat` sees a delivery,
    /// so agents that aren't shown count too.
    let unread: LeoChatUnreadStore
    private let chatRelay: LeoOrderedRelay<LeoChatFeedDelivery>
    /// Windows open Chat for a selected agent with unread messages: on a
    /// selection change, and when a seed lands after one.
    private var unreadOpenSubscriptions: Set<AnyCancellable> = []
    /// Every configured machine, connected at once (This Mac first).
    let machines: LeoMachineRegistry
    /// Each machine's daemon client, handed to actions and control per row.
    let clients: LeoRegistryMachineClients
    /// Agents ▸ Agent Notifications… policy for background transitions.
    let attentionNotifications: LeoAttentionController
    /// One sidebar feed per shown machine.
    let feeds: LeoMachineFeeds
    /// TODO(S6): whether remote machines are fed (and so shown). Off until
    /// the sidebar draws a section per machine: its single-machine list
    /// can't show two machines' sections.
    nonisolated static let feedsRemoteMachinesByDefault = false
    let feedsRemoteMachines: Bool
    private var machinesSubscription: AnyCancellable?
    private var machineStatusesSubscription: AnyCancellable?
    /// Every close of a tab, window or the app with unsaved editor edits
    /// asks through this first (B-004).
    let unsavedEditors = LeoUnsavedEditorsGate()
    /// The start screen's shortcut tooltips, read off the live menu each
    /// time AppDelegate syncs its shortcuts from the config (B-080).
    let shortcutHints = LeoShortcutHints()
    /// Focus identity into `feeds`, delivered in order (see
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
    let localDaemon: any LeoDaemonClient
    let localActivitySource: LeoSidebarActivitySource
    /// Builds a remote machine's client once its tunnel is up.
    let remoteDaemon: LeoRemoteDaemonFactory
    /// Test boundary for direct file-drop routing tests. Production resolves
    /// attachment context and host access from the runtime itself.
    let terminalFileDropDependencies: LeoTerminalFileDropDependencies?
    var terminalFileDropQueues: [UUID: LeoTerminalFileDropQueue] = [:]
    /// Per machine, bumped on EVERY `connectionTarget` transition
    /// (connecting/connected/failed) -- never just when its generation
    /// changes. A machine's generation alone is not enough to guard
    /// `applyConnected`'s async resource build: a `.failed` published for
    /// the SAME generation as a `.connecting` that's still mid-flavor-
    /// detection would otherwise leave the stale `.connected` build free to
    /// install over it once its `await` finally resolves.
    var connectionSequences: [LeoHostID: Int] = [:]
    private(set) var isShutDown = false
    /// Runs the one liveness check per wake (D-061); removed with `self`.
    private var wakeObservation: LeoNotificationObservation?
    /// B5: the managed daemon's launch step, set by the app before `start()`.
    var managedStartup: (@MainActor () async -> Void)?
    #if DEBUG
    private let openFileFixture = LeoOpenFileFixture()
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
        var transport: any LeoDaemonTransport = LeoUnixSocketTransport()
        #if DEBUG
        if let fixture = LeoAttentionFixture.loadFile() {
            activity = LeoAttentionFixture.wrap(activity, overlay: fixture.attention, dispatches: fixture.dispatches, usage: fixture.usage, turns: fixture.turns, actions: fixture.actions, compactions: fixture.compactions, control: fixture.control, dispatchMoves: fixture.dispatchMoves, environments: fixture.environments)
            if let mode = fixture.control { transport = LeoControlFixtureTransport(base: transport, mode: mode) }
            if let environments = fixture.environments { transport = LeoEnvironmentsFixtureTransport(base: transport, fixture: environments) }
        }
        #endif
        let daemon = LeoRuntime.makeClient(socketPath: socketPath, transport: transport)
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
        machineRunner: any LeoProcessRunning = LeoProcessRunner(),
        machineSSHExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
        machineLegacySocketDirectory: URL = LeoTunnelOrphanStore.defaultLegacySocketDirectory,
        machineControlSocketDirectory: URL? = LeoControlSocketDirectory.default,
        makeTunnel: @escaping LeoTunnelFactory = LeoMachineConnectionEnvironment.realTunnel,
        remoteDaemon: LeoRemoteDaemonFactory? = nil,
        machineRetrySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        feedsRemoteMachines: Bool = LeoRuntime.feedsRemoteMachinesByDefault,
        notificationCenter: any LeoNotificationPosting = LeoUserNotificationCenter(),
        focusedAgentSink: (@Sendable (LeoAgentRow.ID?) async -> Void)? = nil,
        wakeNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        terminalFileDropDependencies: LeoTerminalFileDropDependencies? = nil,
        chatClient: (any LeoChatClient)? = nil
    ) {
        // First, before anything that connects a machine reads its defaults.
        LeoMachineDefaultsMigration(defaults: defaults).run()
        self.cli = cli
        self.defaults = defaults
        localDaemon = daemon
        localActivitySource = activitySource
        self.remoteDaemon = remoteDaemon ?? LeoRuntime.tunnelledDaemon(probe: hostConnectionTransport)
        self.feedsRemoteMachines = feedsRemoteMachines
        self.terminalFileDropDependencies = terminalFileDropDependencies
        let orphanStore = LeoTunnelOrphanStore(defaults: defaults, legacySocketDirectory: machineLegacySocketDirectory)
        self.orphanStore = orphanStore
        let model = LeoSidebarModel(
            preferencesStore: LeoUserDefaultsSidebarPreferencesStore(defaults: defaults)
        )
        let registry = LeoWindowSessionRegistry()
        self.model = model
        self.registry = registry
        weak var weakSelf: LeoRuntime?
        attentionNotifications = LeoAttentionController(
            center: notificationCenter, defaults: defaults, isLive: { weakSelf?.feeds.contains($0) ?? false },
            showDeniedInstructions: LeoRuntime.presentNotificationsDeniedInstructions
        )
        let requestConfigStore = LeoRequestConfigStore()
        self.requestConfigStore = requestConfigStore
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: requestConfigStore)
        attachHost = host
        let machines = LeoMachineRegistry(
            store: LeoHostStore(defaults: defaults),
            environment: LeoMachineConnectionEnvironment(
                orphanStore: orphanStore,
                runner: machineRunner,
                sshExecutable: machineSSHExecutable,
                transport: hostConnectionTransport,
                legacySocketDirectory: machineLegacySocketDirectory,
                controlSocketDirectory: machineControlSocketDirectory,
                makeTunnel: makeTunnel
            ),
            sleep: machineRetrySleep,
            connectionTarget: { host, generation, state in
                weakSelf?.applyConnection(host: host, generation: generation, state: state)
            }
        )
        self.machines = machines
        let resolveExecutable = {
            let override = defaults.string(forKey: "leo.executablePath")
            return try LeoCLI(executableOverride: override, runner: cli.runner).resolveExecutable()
        }
        let dispatchAccessProbe = LeoDispatchAccessProbe(
            runner: machineRunner,
            executable: resolveExecutable,
            sshExecutable: machineSSHExecutable.path,
            hosts: { [weak machines] in machines?.configurations ?? [] }
        )
        attachCoordinator = LeoAttachCoordinator(
            host: host,
            executable: resolveExecutable,
            remoteCommandBuilder: { [weak machines, weak model] identity, access in
                guard let configuration = machines?.configuration(for: identity.host) else {
                    throw LeoDaemonError.hostUnavailable("Remote host \(identity.host.displayName) is not configured")
                }
                let command = LeoSSHCommand(configuration: configuration)
                if let dispatchID = identity.dispatchID { return try command.attachShellCommand(dispatchID: dispatchID, access: access) }
                return try command.attachShellCommand(agent: identity.name, features: model?.features(for: identity.host) ?? .none)
            },
            dispatchAccess: { host in await dispatchAccessProbe.access(for: host) },
            daemonFeatures: { [weak model] host in model?.features(for: host) ?? .none },
            report: { [weak model] error in
                // A dispatch has no row of its own to carry the error.
                if error.identity.dispatchID != nil {
                    model?.setPanelError(error.message)
                    return
                }
                let id = LeoAgentRow.ID(host: error.identity.host, name: error.identity.name)
                model?.setRowError(error.message, for: id)
            },
            lifecycleEventHandled: { _ in weakSelf?.terminalFileDropContextDidChange() },
            attachmentChanged: { weakSelf?.terminalFileDropContextDidChange() },
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
        registry.onUnregistered = { [weak router, weak pickerRouter, weak attachCoordinator, weak requestConfigStore] windowID in
            requestConfigStore?.releaseStartScreen(windowID)
            router?.invalidate(origin: windowID)
            pickerRouter?.unregister(origin: windowID)
            attachCoordinator?.windowClosed(windowID)
        }

        // `actions` doesn't exist yet at the point `feeds` is constructed
        // (its `refresh` closure below needs `feeds`), so the feeds'
        // manual-refresh callback is wired through this box instead of
        // capturing `actions` directly -- filled in immediately after
        // `actions` is created.
        // Captured strongly by the feeds' closure below (kept alive exactly
        // as long as `feeds` is), while the box itself only holds `actions`
        // weakly -- so this cannot create a `feeds` <-> `actions` retain
        // cycle even though `actions`' own `refresh` closure also captures
        // `feeds` (weakly, see below).
        let actionsBox = LeoAgentActionsBox()
        let localChatClient = chatClient ?? LeoChatPaneModel.makeClient(
            socketPath: NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath, transport: LeoUnixSocketTransport()
        )
        let unread = LeoChatUnreadStore(client: localChatClient, host: .local)
        self.unread = unread
        let chat = LeoChatPaneModel(
            client: localChatClient, host: .local, recorder: LeoChatVoiceRecorder(),
            attachmentDirectory: LeoChatPaneModel.defaultAttachmentDirectory,
            onRead: { [weak unread] in unread?.clear($0) }
        )
        self.chat = chat
        let chatRelay = LeoOrderedRelay<LeoChatFeedDelivery> { [weak chat, weak unread, weak registry] delivery in
            // Count first (a shown, read agent doesn't count), then let a
            // window showing the sending agent's terminal open Chat, then the
            // pane merges the message and marks it read.
            await MainActor.run {
                unread?.receive(delivery, isOnScreen: { chat?.marksRead($0) ?? false })
                if let agent = LeoChatAutoOpen.agent(sending: delivery) {
                    registry?.sessions.forEach { $0.openChatIfSent(by: agent) }
                }
            }
            await chat?.handle(delivery)
        }
        self.chatRelay = chatRelay
        // `@Published` sends before it stores; hop a turn so the session's
        // selection and the store's counts read the new values.
        model.$selection.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak registry, weak unread] _ in
                MainActor.assumeIsolated {
                    guard let unread else { return }
                    registry?.sessions.forEach { $0.selectionChanged(unreadCount: unread.count(for:)) }
                }
            }
            .store(in: &unreadOpenSubscriptions)
        unread.$counts.receive(on: DispatchQueue.main)
            .sink { [weak registry, weak unread] _ in
                MainActor.assumeIsolated {
                    guard let unread else { return }
                    registry?.sessions.forEach { $0.unreadChanged(unreadCount: unread.count(for:)) }
                }
            }
            .store(in: &unreadOpenSubscriptions)
        let feeds = LeoMachineFeeds(dependencies: .init(
            localDaemon: daemon, localActivity: activitySource,
            onManualRefresh: { [actionsBox] in actionsBox.actions?.invalidateTemplateCache() },
            onAttentionTransitions: { transitions in weakSelf?.attentionTransitionsCommitted(transitions) },
            onChat: { signal in chatRelay.send(LeoChatFeedDelivery(host: .local, signal: signal)) },
            onSnapshot: { [weak model] host, snapshot in
                model?.receive(snapshot, for: host)
                // B-270: a hello advertising dispatch placement re-attaches
                // what attached before it.
                weakSelf?.attachCoordinator.daemonFeaturesChanged()
                weakSelf?.snapshotLanded(snapshot)
            }
        ))
        self.feeds = feeds
        focusedAgentRelay = LeoOrderedRelay(sink: focusedAgentSink ?? { [weak feeds] id in await feeds?.setFocusedAgent(id) })
        let clients = LeoRegistryMachineClients(registry: machines)
        self.clients = clients
        actions = LeoAgentActions(clients: clients, cli: cli, model: model, processRunner: templateFetchRunner) {
            Task { @MainActor [weak feeds] in feeds?.refresh() }
        }
        actionsBox.actions = actions
        control = LeoAgentControlModel(clients: clients, confirmClear: { row, window in
            await LeoClearConfirmation.confirm(agent: row.name, in: window)
        })
        model.startRequested = { [weak actions] row, completion in actions?.start(row, completion: completion) }
        // Agents ▸ Reconnect (Q7): every machine whose sidebar offers Retry.
        model.retryRequested = { [weak machines, weak model] in
            LeoMenuCommands.machinesToReconnect(model?.machineConnectivity ?? []).forEach { machines?.reconnect($0) }
        }
        model.reconnectRequested = { [weak machines] host in machines?.reconnect(host) }
        model.connectionFailureHint = { [weak machines] host in
            guard let hint = machines?.connectionState(for: host)?.failureHint,
                  let target = machines?.configuration(for: host)?.sshTarget else { return nil }
            return LeoConnectionFailureHint(hint: hint, sshTarget: target)
        }
        registry.pollabilityChanged = { [weak feeds] pollable in feeds?.setPolling(pollable) }
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
            model?.selectAgentRow(row.id)
            Task { await attachCoordinator?.attach(identity: row.identity, from: origin, disposition: disposition) }
        }
        model.dispatchAttachRequested = { [weak attachCoordinator] identity, origin, disposition in
            Task { await attachCoordinator?.attach(identity: identity, from: origin, disposition: disposition) }
        }
        model.focusExistingRequested = { [weak attachCoordinator] row, origin in
            attachCoordinator?.focusExisting(row.identity, from: origin)
        }
        let paneFocuser = LeoDispatchPaneFocuser(runner: machineRunner)
        model.dispatchPaneFocusRequested = { [weak machines, weak model] host, pane, rowID in
            let hosts = machines?.configurations ?? []
            Task { @MainActor in
                do {
                    let command = try LeoDispatchPaneFocus.command(
                        host: host, pane: pane, hosts: hosts, sshExecutable: machineSSHExecutable.path
                    )
                    try await paneFocuser.focus(command)
                } catch {
                    model?.setRowError(LeoDispatchPaneFocusError.message(for: error), for: rowID)
                }
            }
        }
        model.latestFocusReport = { [weak attachCoordinator] in attachCoordinator?.latestFocusReport ?? 0 }

        // `machines`' `connectionTarget` (wired above) closes over
        // `weakSelf`, which can only be set once `self` is fully
        // initialized -- every machine's state transition
        // (connecting/connected/failed), tagged with the generation it
        // belongs to, drives that machine's feed and client.
        weakSelf = self
        // Fires at once with today's machines, so the model and feeds know
        // them before any feed delivers (no phantom This Mac section).
        machinesSubscription = machines.$machines.sink { [weak self] in self?.machinesChanged($0) }
        machineStatusesSubscription = machines.machineStatuses.sink { [weak self] in self?.machineStatusesChanged($0) }
        // B-274: a window's editor and browser follow the row it shows.
        attachCoordinator.onRowShown = { [weak registry] windowID, key in
            registry?.session(for: windowID)?.panes.activate(key)
        }
        actions.closePanes = { [weak registry] row in
            for session in registry?.sessions ?? [] {
                guard await session.panes.close(.agent(row.identity)) else { return false }
            }
            return true
        }
        // One immediate liveness check per wake, never repeated: a tunnel
        // or socket that died in sleep shows as disconnected (D-061).
        wakeObservation = LeoNotificationObservation(center: wakeNotifications, name: NSWorkspace.didWakeNotification) { [weak feeds] in
            Task { @MainActor in feeds?.checkLiveness() }
        }
        #if DEBUG
        if let reason = LeoForcedDisconnectFixture.reason() {
            forcedDisconnect = LeoForcedDisconnectFixture.arm(model: model, reason: reason) { [weak feeds] reason in
                feeds?.disconnect(.local, reason: reason)
            }
        }
        #endif
    }

    /// Every snapshot the model receives.
    private func snapshotLanded(_ snapshot: LeoSidebarSnapshot) {
        prunePanes(for: snapshot)
    }

    /// B-274: agents (and dispatches) a connected host no longer lists lose
    /// their panes. Only a list fetched while connected counts -- a failed
    /// fetch or a dropped connection says nothing about who's gone -- and
    /// dispatches only once the host advertises its dispatch tree.
    private func prunePanes(for snapshot: LeoSidebarSnapshot) {
        guard snapshot.connectivity == .connected, snapshot.listRefreshSucceeded, let host = snapshot.advertised.host else { return }
        let names = Set(snapshot.rows.map(\.name))
        let dispatches = Set(snapshot.dispatchChildren.values.flatMap { $0.map(\.id) })
        let knowsDispatches = snapshot.features.contains(.dispatchTree)
        for session in registry.sessions {
            session.panes.pruneAgents(on: host) { name, dispatchID in
                guard let dispatchID else { return names.contains(name) }
                return !knowsDispatches || dispatches.contains(dispatchID)
            }
        }
    }

    func start() {
        Self.logger.log("start() called")
        let orphanStore = orphanStore
        Task {
            // Must run before any tunnel this launch might start, so a
            // leftover record always describes a process untouched this run.
            await Task.detached {
                orphanStore.reapAtLaunch(inspector: leoTunnelRealInspector, signaller: leoTunnelRealSignaller)
            }.value
            // B5: set up or adopt the local daemon before anything asks it
            // for its flavor or connects to it.
            await managedStartup?()
            let flavor = await LeoSocketDaemonClient.detectFlavor()
            Self.logger.log("detected flavor=\(String(describing: flavor), privacy: .public)")
            feeds.start(pollable: registry.hasPollableSidebar)
            machines.start(flavor: flavor)
        }
    }

    /// The app restarted or switched its own daemon: reconnect This Mac.
    /// Every remote machine keeps its tunnel and feed.
    func localDaemonChanged() {
        machines.reconnect(.local)
    }

    /// The quit hook: tears every tunnel down at once under one bound.
    func shutdown() {
        isShutDown = true
        cancelTerminalFileDrops()
        machines.shutdown()
        feeds.stop()
    }
    func makeWindowSession(for controller: TerminalController) -> LeoWindowSession {
        let session = registry.makeSession(
            window: controller.window, controller: controller, defaults: defaults,
            makeFileAccess: { [weak machines] host in
                guard let machines else { throw LeoFileAccessError.unavailable(reason: "Leo is shutting down") }
                let access = try machines.makeFileAccess(for: host)
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
        session.selectedAgent = { [weak self] in self?.model.actionableSelection?.id }
        session.unreadCount = { [weak unread] in unread?.count(for: $0) ?? 0 }
        session.latestAgentMessageKind = { [weak unread] in unread?.latestAgentKind(for: $0) }
        // A new window comes up on the shared selection without moving it.
        session.selectionChanged(unreadCount: session.unreadCount)
        wireTerminals(session.terminals, window: sessionID)
        if let window = controller.window {
            let presentation = LeoPickerPresentation(
                window: window,
                router: newSurfaceRouter,
                sidebar: model,
                machines: machines,
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

    /// The agent palette's window for the window session `windowID`: built
    /// with the session, hidden until ⌘O (B-142).
    func paletteWindow(for windowID: LeoWindowID) -> NSWindow? {
        picker.paletteWindow(for: windowID)
    }

    /// Tears down everything scoped to `windowID`: any pending new-surface
    /// request, that window's palette presentation (panel, model,
    /// subscriptions) and its attach bookkeeping. Idempotent -- safe to call from both
    /// `LeoWindowSession.onWindowWillClose` (prompt path) and
    /// `registry.onUnregistered` (fallback reconciliation), which may both
    /// fire for the same window.
    private func teardownWindow(_ windowID: LeoWindowID) {
        requestConfigStore.releaseStartScreen(windowID)
        newSurfaceRouter.invalidate(origin: windowID)
        picker.unregister(origin: windowID)
        attachCoordinator.windowClosed(windowID)
    }

    /// B-145: `window` opened as a bare start screen, with no palette to
    /// carry `config` (whatever ⌘N inherited) to the first surface that
    /// fills it -- see `LeoRequestConfigStore.hold(_:forStartScreen:)`.
    func holdStartScreenConfig(_ config: Ghostty.SurfaceConfiguration?, for window: LeoWindowID) {
        requestConfigStore.hold(config, forStartScreen: window)
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
            observedState: {
                if await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath) == .socketEvents {
                    return try await LeoSocketActivityClient(socketPath: socketPath).fetchState()
                }
                let config = await Task.detached { LeoObserveConfigLoader.load() }.value
                guard let config else { return LeoObservedState(agents: []) }
                return try await LeoActivityClient(config: config).fetchState()
            }
        )
    }
}

/// Breaks the `feeds` <-> `actions` construction cycle in `LeoRuntime.init`:
/// the feeds' list-refresh callback needs to reach `actions`, but `actions`
/// isn't constructed until after `feeds` (its own `refresh` closure needs
/// `feeds`). Held weakly by the callback and filled in once, immediately
/// after `actions` exists.
@MainActor private final class LeoAgentActionsBox: @unchecked Sendable {
    weak var actions: LeoAgentActions?
}
