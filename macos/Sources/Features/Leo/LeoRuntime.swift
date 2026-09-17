import AppKit
import Foundation
import GhosttyKit
import OSLog

@MainActor final class LeoRuntime {
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo")

    let model: LeoSidebarModel
    let registry: LeoWindowSessionRegistry
    let actions: LeoAgentActions
    let hostSelection: LeoHostSelection
    private let feed: LeoSidebarFeed
    private let cli: LeoCLI
    private let defaults: UserDefaults
    private let attachCoordinator: LeoAttachCoordinator
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

    init(
        daemon: any LeoDaemonClient, cli: LeoCLI, activitySource: LeoSidebarActivitySource, defaults: UserDefaults = .standard,
        hostConnectionTransport: any LeoDaemonTransport = LeoUnixSocketTransport(),
        hostSelectionRunner: any LeoProcessRunning = LeoProcessRunner(),
        hostSelectionSSHExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh")
    ) {
        self.cli = cli
        self.defaults = defaults
        localDaemon = daemon
        localActivitySource = activitySource
        self.hostConnectionTransport = hostConnectionTransport
        let orphanStore = LeoTunnelOrphanStore(defaults: defaults)
        self.orphanStore = orphanStore
        let model = LeoSidebarModel()
        let registry = LeoWindowSessionRegistry()
        self.model = model
        self.registry = registry
        let requestConfigStore = LeoRequestConfigStore()
        self.requestConfigStore = requestConfigStore
        let host = GhosttyAttachTabHost(registry: registry, requestConfigStore: requestConfigStore)
        weak var weakSelf: LeoRuntime?
        let hostSelection = LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            runner: hostSelectionRunner,
            sshExecutable: hostSelectionSSHExecutable,
            transport: hostConnectionTransport,
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
        let pickerRouter = LeoWindowPickerRouter()
        let router = LeoNewSurfaceRouter(
            attach: { [weak attachCoordinator] identity, request in
                guard let attachCoordinator else {
                    return .failure(.init(identity: identity, kind: .openFailed("Leo runtime is unavailable")))
                }
                return await attachCoordinator.attach(identity: identity, request: request).map { _ in () }
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
                if case .placeholder = request.disposition { return controller.surfaceTree.isEmpty }
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
        // Both call `router.invalidate`/`pickerRouter.unregister`, which are
        // idempotent, so running it twice for the same window is harmless.
        registry.onUnregistered = { [weak router, weak pickerRouter] windowID in
            router?.invalidate(origin: windowID)
            pickerRouter?.unregister(origin: windowID)
        }

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
        let session = registry.makeSession(window: controller.window, controller: controller, defaults: defaults)
        // Captures `sessionID` (a value), not `session` itself -- `session`
        // owns this closure, so capturing `session` here would be a
        // reference cycle (session -> closure -> session) that keeps the
        // window session, and everything it holds, alive forever.
        let sessionID = session.id
        session.openPicker = { [weak self, weak controller] in
            guard let self else { return }
            let disposition: LeoSurfaceDisposition = (controller?.surfaceTree.isEmpty ?? true) ? .placeholder : .tab
            self.routeNewSurface(disposition, origin: sessionID)
        }
        session.onWindowWillClose = { [weak self] in self?.teardownWindow(sessionID) }
        if let window = controller.window {
            let presentation = LeoPickerPresentation(
                window: window,
                router: newSurfaceRouter,
                sidebar: model,
                hostSelection: hostSelection,
                actions: actions
            )
            picker.register(presentation, for: sessionID)
        }
        return session
    }

    func makeWindowSession() -> LeoWindowSession {
        registry.makeSession(defaults: defaults)
    }

    /// Tears down everything scoped to `windowID`: any pending new-surface
    /// request and that window's palette presentation (panel, model,
    /// subscriptions). Idempotent -- safe to call from both
    /// `LeoWindowSession.onWindowWillClose` (prompt path) and
    /// `registry.onUnregistered` (fallback reconciliation), which may both
    /// fire for the same window.
    private func teardownWindow(_ windowID: LeoWindowID) {
        newSurfaceRouter.invalidate(origin: windowID)
        picker.unregister(origin: windowID)
    }

    /// Begins a new-surface gesture (Cmd+T, Cmd+D, Cmd+N, launch, or the
    /// placeholder's "pick an agent" button) for `origin` and immediately
    /// hands it to the picker. `sourceSurface` is required for `.split` and
    /// ignored otherwise (see `LeoSurfaceRequest`). `inheritedConfig` is the
    /// `Ghostty.SurfaceConfiguration` the triggering gesture carried (e.g.
    /// the focused surface's working directory) -- stashed in
    /// `requestConfigStore` keyed by the request's id, since
    /// `LeoSurfaceRequest` itself stays a pure value type with no AppKit
    /// dependency. `GhosttyAttachTabHost` consumes it when it actually
    /// creates the destination surface.
    func routeNewSurface(
        _ disposition: LeoSurfaceDisposition,
        origin: LeoWindowID,
        sourceSurface: UUID? = nil,
        inheritedConfig: Ghostty.SurfaceConfiguration? = nil
    ) {
        let request = LeoSurfaceRequest(origin: origin, disposition: disposition, splitSourceSurface: sourceSurface)
        Self.logger.log("routeNewSurface disposition=\(String(describing: disposition), privacy: .public) origin=\(origin.rawValue.uuidString, privacy: .public)")
        requestConfigStore.set(inheritedConfig, for: request.id)
        newSurfaceRouter.begin(request)
        picker.present(request: request)
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
            daemon = LeoSocketDaemonClient(socketPath: socketPath)
            let remoteFlavor = await LeoSocketDaemonClient.detectFlavor(socketPath: socketPath, transport: hostConnectionTransport)
            activitySource = remoteFlavor == .socketEvents
                ? LeoSidebarActivitySource(
                    events: { await LeoSocketActivityClient(socketPath: socketPath).events() },
                    fetchState: { try await LeoSocketActivityClient(socketPath: socketPath).fetchState() }
                  )
                : LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        }
        guard sequence == connectionSequence else { return }
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
