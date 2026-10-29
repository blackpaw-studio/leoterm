import AppKit
import GhosttyKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-333: one window's terminal rows and their split layouts against a real
/// `TerminalController` and host, wired as `LeoRuntime` wires the app's own
/// sessions. Needs the app's real `Ghostty.App`.
///
/// The window is built but never shown or made key, and no alert is ever
/// put up: its controller records each close confirm and answers it with
/// `answer`. An "agent" here runs `/bin/cat`, never a real agent.
@MainActor final class LeoRowLayoutFixture {
    static let standIn = "/bin/cat"

    /// A window controller whose close confirms are recorded and answered
    /// instead of shown.
    @MainActor final class Controller: TerminalController {
        struct Asked: Equatable {
            let messageText: String
            let informativeText: String
        }

        var asked: [Asked] = []
        var answer: NSApplication.ModalResponse = .alertSecondButtonReturn

        override func confirmCloseAsync(
            messageText: String,
            informativeText: String,
            confirmButtonTitle: String = "Close"
        ) async -> NSApplication.ModalResponse? {
            asked.append(Asked(messageText: messageText, informativeText: informativeText))
            return answer
        }
    }

    let host: GhosttyAttachContentHost
    let configs: LeoRequestConfigStore
    let controller: Controller
    /// Where requests are routed from (the host's registry entry).
    let origin: LeoWindowID
    /// The window's own session: its sidebar, and its handles' and hidden
    /// surfaces' window id.
    let session: LeoWindowSession
    private(set) var events: [AttachLifecycleEvent] = []
    private(set) var windowClosed = false
    private var eventTask: Task<Void, Never>?
    private var closeObserver: NSObjectProtocol?

    var windowID: LeoWindowID { session.id }
    var terminals: LeoWindowTerminals { session.terminals }
    func shown() -> [Ghostty.SurfaceView] { Array(controller.surfaceTree) }
    func view(_ handle: AttachmentHandle) -> Ghostty.SurfaceView? { shown().first { $0.id == handle.surfaceID } }
    func handle(_ view: Ghostty.SurfaceView) -> AttachmentHandle { AttachmentHandle(surfaceID: view.id, windowID: windowID) }
    func kept() -> [Ghostty.SurfaceView] { host.hiddenSurfaces(in: windowID) }

    private static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    /// `startScreen`: the window opens on an empty start screen, as a
    /// restored one does (B-332), rather than showing a shell no row owns.
    init(startScreen: Bool = false) throws {
        let ghostty = try #require(Self.ghostty, "these tests need the app's Ghostty.App")
        let app = try #require(ghostty.app)
        controller = startScreen
            ? Controller(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
            : Controller(ghostty, withSurfaceTree: SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil)))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let registry = LeoWindowSessionRegistry()
        origin = registry.makeSession(window: controller.window, controller: controller, defaults: LeoInMemoryDefaults()).id
        session = try #require(controller.leoSession)
        configs = LeoRequestConfigStore()
        let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: configs) { .init(isActive: false, keyWindow: nil) }
        self.host = host
        // What `LeoRuntime` wires for the app's own sessions, less the
        // coordinator: a reveal here never asks.
        let window = session.id
        let handle: (UUID) -> AttachmentHandle = { AttachmentHandle(surfaceID: $0, windowID: window) }
        session.terminals.showRequested = { [weak host] in _ = host?.reveal(handle($0)) }
        session.terminals.closeRequested = { [weak host] in host?.closeTerminal(handle($0)) }
        session.terminals.hasBusyHiddenShell = { [weak host] in host?.hiddenTerminalsNeedConfirmQuit(in: window) ?? false }
        session.splitsIntoShell = { [weak host] in host?.splitsIntoShell(in: window) ?? false }
        session.registerSplitShell = { [weak host] in host?.registerSplitShell($0, in: window) }
        session.savedTerminals = { [weak host] in host?.savedTerminals(in: window) }
        eventTask = Task { [weak self, events = host.lifecycleEvents] in
            for await event in events { self?.events.append(event) }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.windowClosed = true } }
    }

    func close() {
        eventTask?.cancel()
        closeObserver.map(NotificationCenter.default.removeObserver)
        guard !windowClosed else { return }
        controller.closeTabImmediately(registerRedo: false)
    }

    /// A new terminal row, as ⌘T makes one. `command` stands in for what
    /// its shell runs; `waiting`: once it ends, Ghostty waits for a key.
    func newRow(running command: String? = nil, waiting: Bool = false) throws -> AttachmentHandle {
        try host.showInContent(command: "", workingDirectory: nil, origin: origin, requestID: request(running: command, waiting: waiting))
    }

    func attachAgent() throws -> AttachmentHandle {
        try host.showInContent(command: Self.standIn, workingDirectory: nil, origin: origin, requestID: UUID())
    }

    /// ⌘D (or ⇧⌘D) on `pane`: Ghostty's `new_split`, with the config it
    /// inherits from `pane` -- unless `running` names what the new pane
    /// runs instead of a shell. `nil` when it made no split here.
    func split(
        _ pane: Ghostty.SurfaceView,
        _ direction: SplitTree<Ghostty.SurfaceView>.NewDirection = .right,
        running command: String? = nil,
        waiting: Bool = false
    ) -> Ghostty.SurfaceView? {
        var config = pane.surface.map { Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_SPLIT)) }
        if let command {
            config?.command = command
            config?.waitAfterCommand = waiting
        }
        return controller.newSplit(at: pane, direction: direction, baseConfig: config)
    }

    /// A Ghostty keybind action on `view`, as its key (⌘D is
    /// `new_split:right`) runs it: through the core, so the split it asks
    /// for inherits from `view` as Ghostty's own does.
    @discardableResult
    func perform(_ action: String, on view: Ghostty.SurfaceView) -> Bool {
        guard let surface = view.surface else { return false }
        return ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
    }

    /// The split at the root of what the window shows.
    var rootSplit: SplitTree<Ghostty.SurfaceView>.Node.Split? {
        guard case .split(let split)? = controller.surfaceTree.root else { return nil }
        return split
    }

    /// A shell beside `pane` through the picker's committed path, as a
    /// split beside an agent is made.
    func pickerSplit(beside pane: AttachmentHandle, running command: String? = nil) throws -> AttachmentHandle {
        try host.openSplit(
            command: "", workingDirectory: nil, origin: origin,
            sourceSurface: pane.surfaceID, direction: .right, requestID: request(running: command, waiting: false)
        )
    }

    private func request(running command: String?, waiting: Bool) -> UUID {
        let requestID = UUID()
        guard command != nil || waiting else { return requestID }
        var config = Ghostty.SurfaceConfiguration()
        config.command = command
        config.waitAfterCommand = waiting
        configs.set(config, for: requestID)
        return requestID
    }

    /// ⌘W on `view`, one of a split's panes (its confirm answered): the
    /// controller's own undoable close.
    func closePane(_ view: Ghostty.SurfaceView) throws {
        let node = try #require(controller.surfaceTree.root?.node(view: view))
        controller.closeSurface(node, withConfirmation: false)
    }

    /// Ghostty's close request for `view`, as its process ending sends it.
    func postCloseRequest(_ view: Ghostty.SurfaceView, processAlive: Bool = false) {
        NotificationCenter.default.post(name: Ghostty.Notification.ghosttyCloseSurface, object: view, userInfo: ["process_alive": processAlive])
    }

    /// Polls `condition` for up to `timeout` of wall time: for what waits
    /// on a timer, a process, SwiftUI or an object's release.
    func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Lets the main run loop turn until `condition` holds, at most
    /// `limit` times: counts turns, not time (D-178).
    func turnsUntil(limit: Int = 50, _ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< limit {
            if condition() { return true }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        return condition()
    }

    /// `view` has become the window's first responder. `Ghostty.moveFocus`
    /// retries on timers while the view isn't in the window yet.
    func focusLands(on view: Ghostty.SurfaceView?) async -> Bool {
        guard let view else { return false }
        return await eventually(.seconds(10)) { controller.window?.firstResponder === view }
    }
}
