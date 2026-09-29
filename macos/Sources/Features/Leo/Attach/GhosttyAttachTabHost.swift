import AppKit
import Combine
import GhosttyKit
import OSLog

@MainActor final class GhosttyAttachTabHost: AttachTabHost {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    let lifecycleEvents: AsyncStream<AttachLifecycleEvent>
    private let continuation: AsyncStream<AttachLifecycleEvent>.Continuation
    private let registry: LeoWindowSessionRegistry
    private let requestConfigStore: LeoRequestConfigStore
    private var attachments: [AttachmentHandle: Attachment] = [:]
    private var focusObservers: [NSObjectProtocol] = []
    private var reportedFocus: AttachLifecycleEvent?
    private var reportedViewing: AttachmentHandle?
    private(set) var focusReportCount = 0
    private let appFocusState: @MainActor () -> AppFocusState

    /// Whether the app is active and which window is key. Injectable so
    /// tests can drive focus reports without the real app being frontmost.
    struct AppFocusState {
        var isActive: Bool
        var keyWindow: NSWindow?

        @MainActor static func current() -> AppFocusState {
            AppFocusState(isActive: NSApp.isActive, keyWindow: NSApp.keyWindow)
        }
    }

    init(
        registry: LeoWindowSessionRegistry,
        requestConfigStore: LeoRequestConfigStore,
        appFocusState: @escaping @MainActor () -> AppFocusState = AppFocusState.current
    ) {
        self.registry = registry
        self.requestConfigStore = requestConfigStore
        self.appFocusState = appFocusState
        (lifecycleEvents, continuation) = AsyncStream.makeStream()
        observeFocus()
    }

    deinit {
        continuation.finish()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// `viewedHandle`, but only while that surface is the window's first
    /// responder: the controller keeps remembering `focusedSurface` after
    /// keyboard focus moves to the sidebar.
    var focusedHandle: AttachmentHandle? {
        let state = appFocusState()
        return focusedHandle(isActive: state.isActive, keyWindow: state.keyWindow)
    }

    /// Key window -> its controller -> `focusedSurface`, so a
    /// focused split counts, first responder or not. `nil` while the app is
    /// inactive.
    var viewedHandle: AttachmentHandle? {
        let state = appFocusState()
        return viewedHandle(isActive: state.isActive, keyWindow: state.keyWindow)
    }

    /// `focusedHandle` for the given app state (injectable for tests).
    func focusedHandle(isActive: Bool, keyWindow: NSWindow?) -> AttachmentHandle? {
        guard let handle = viewedHandle(isActive: isActive, keyWindow: keyWindow),
              attachments[handle]?.surface?.isFirstResponder == true else { return nil }
        return handle
    }

    /// `viewedHandle` for the given app state (injectable for tests).
    func viewedHandle(isActive: Bool, keyWindow: NSWindow?) -> AttachmentHandle? {
        guard isActive, let controller = keyWindow?.windowController as? BaseTerminalController,
              let surface = controller.focusedSurface else { return nil }
        return attachments.first { $0.value.controller === controller && $0.value.surface === surface }?.key
    }

    /// What `reportFocus` yields for the given app state. Deactivation (or
    /// the gap between one window resigning key and the next becoming key)
    /// suspends focus rather than moving it.
    func focusEvent(isActive: Bool, keyWindow: NSWindow?) -> AttachLifecycleEvent {
        guard isActive, let keyWindow else { return .focusSuspended }
        return .focusChanged(focusedHandle(isActive: true, keyWindow: keyWindow))
    }

    private func observeFocus() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            .leoFocusedSurfaceDidChange
        ]
        focusObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportFocus() }
            }
        }
        // A surface resigning first responder is told before the window's
        // `firstResponder` moves on, so read it on the next turn.
        focusObservers.append(NotificationCenter.default.addObserver(
            forName: .leoSurfaceFocusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.reportFocus() }
        })
    }

    /// Viewing first: a `.focusChanged` onto an attachment implies it is
    /// viewed, so the two never disagree once both are delivered.
    private func reportFocus() {
        let viewing = viewedHandle
        if viewing != reportedViewing {
            reportedViewing = viewing
            yieldFocusReport(.viewingChanged(viewing))
        }
        let state = appFocusState()
        let event = focusEvent(isActive: state.isActive, keyWindow: state.keyWindow)
        guard event != reportedFocus else { return }
        reportedFocus = event
        yieldFocusReport(event)
    }

    private func yieldFocusReport(_ event: AttachLifecycleEvent) {
        focusReportCount += 1
        continuation.yield(event)
    }

    /// B-055: a row shown in `origin`'s one content area. The empty start
    /// screen is filled (sized as a new window's first surface); anything
    /// else -- one surface or a whole split tree -- is swapped out whole
    /// for the new surface, in the same window beside the same sidebar.
    func showInContent(command: String, workingDirectory: String?, origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle {
        guard let controller = registry.controller(for: origin) else { throw GhosttyAttachTabHostError.originWindowClosed }
        if controller.surfaceTree.isEmpty {
            return try fillPlaceholder(command: command, workingDirectory: workingDirectory, origin: origin, surfaceID: nil, requestID: requestID)
        }
        let newView = try makeSurface(in: controller, command: command, workingDirectory: workingDirectory, requestID: requestID)
        let displaced = controller.leoReplaceContent(with: SplitTree(view: newView), focusing: newView)
        retire(displaced, from: controller)
        Self.logger.log("showInContent requestID=\(requestID.uuidString, privacy: .public) replaced=\(Array(displaced).count)")
        return try register(controller, surface: newView)
    }

    func confirmReplacingContent(origin: LeoWindowID) async -> Bool {
        guard let controller = registry.controller(for: origin) else { return true }
        let shown = controller.surfaceTree.map {
            LeoContentReplacement.Shown(isAgent: $0.leoAgentName != nil, needsConfirmQuit: $0.needsConfirmQuit)
        }
        guard LeoContentReplacement.needsConfirmation(shown) else { return true }
        let response = await controller.confirmCloseAsync(
            messageText: LeoContentReplacement.messageText,
            informativeText: LeoContentReplacement.informativeText,
            confirmButtonTitle: LeoContentReplacement.confirmButtonTitle
        )
        // `nil`: another alert is already up on this window -- don't close.
        return response.map { [.alertFirstButtonReturn, .OK].contains($0) } ?? false
    }

    /// What leaves the content area on a switch. B-055 lets it go: once
    /// the tree is dropped nothing holds its surfaces, so each frees its
    /// Ghostty surface and pty, and an attach's tmux client detaches
    /// (`register`'s tree observer then reports its handle `.closed`).
    /// B-056's pool keeps the most recent ones here instead. Exited attach
    /// panes stop counting as placeholders.
    private func retire(_ displaced: SplitTree<Ghostty.SurfaceView>, from controller: TerminalController) {
        displaced.forEach { controller.leoSession?.fillPlaceholder(surfaceID: $0.id) }
    }

    private func makeSurface(
        in controller: TerminalController,
        command: String,
        workingDirectory: String?,
        requestID: UUID
    ) throws -> Ghostty.SurfaceView {
        guard let ghosttyApp = controller.ghostty.app else { throw GhosttyAttachTabHostError.noTerminalWindow }
        let view = Ghostty.SurfaceView(
            ghosttyApp,
            baseConfig: configuration(command: command, workingDirectory: workingDirectory, requestID: requestID)
        )
        guard view.surface != nil else { throw GhosttyAttachTabHostError.surfaceUnavailable }
        return view
    }

    func openWindow(command: String, workingDirectory: String?, requestID: UUID) throws -> AttachmentHandle {
        guard let ghostty = TerminalController.preferredParent?.ghostty else { throw GhosttyAttachTabHostError.noTerminalWindow }
        let controller = TerminalController.newWindow(
            ghostty,
            withBaseConfig: configuration(command: command, workingDirectory: workingDirectory, requestID: requestID)
        )
        guard let surface = controller.surfaceTree.first else { throw GhosttyAttachTabHostError.surfaceUnavailable }
        return try register(controller, surface: surface)
    }

    /// Always creates a new split off `sourceSurface`, even if that surface
    /// already has other splits -- `.split` never reuses (see
    /// `AttachTabHost.openSplit`).
    func openSplit(
        command: String,
        workingDirectory: String?,
        origin: LeoWindowID,
        sourceSurface: UUID,
        direction: LeoSplitDirection,
        requestID: UUID
    ) throws -> AttachmentHandle {
        Self.logger.log("openSplit requestID=\(requestID.uuidString, privacy: .public) origin=\(origin.rawValue.uuidString, privacy: .public)")
        do {
            guard let controller = registry.controller(for: origin) else { throw GhosttyAttachTabHostError.originWindowClosed }
            guard let sourceView = controller.surfaceTree.first(where: { $0.id == sourceSurface }) else {
                throw GhosttyAttachTabHostError.splitSourceUnavailable
            }
            guard let newView = controller.leoCreateSplit(
                at: sourceView,
                direction: leoSplitTreeDirection(for: direction),
                baseConfig: configuration(command: command, workingDirectory: workingDirectory, requestID: requestID)
            ) else { throw GhosttyAttachTabHostError.cannotOpenSplit }
            let handle = try register(controller, surface: newView)
            Self.logger.log("openSplit requestID=\(requestID.uuidString, privacy: .public) result=success")
            return handle
        } catch {
            Self.logger.log("openSplit requestID=\(requestID.uuidString, privacy: .public) result=failure error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Replaces the origin window's empty surface tree with a freshly
    /// created attach surface. Refuses (throws) if the tree is not empty --
    /// there is nothing to "fill" otherwise, and this must never clobber a
    /// live split.
    func fillPlaceholder(command: String, workingDirectory: String?, origin: LeoWindowID, surfaceID: UUID?, requestID: UUID) throws -> AttachmentHandle {
        Self.logger.log("fillPlaceholder requestID=\(requestID.uuidString, privacy: .public) origin=\(origin.rawValue.uuidString, privacy: .public)")
        do {
            guard let controller = registry.controller(for: origin) else { throw GhosttyAttachTabHostError.originWindowClosed }
            if surfaceID == nil { guard controller.surfaceTree.isEmpty else { throw GhosttyAttachTabHostError.placeholderNotEmpty } }
            let newView = try makeSurface(in: controller, command: command, workingDirectory: workingDirectory, requestID: requestID)

            if let surfaceID {
                guard let oldView = controller.surfaceTree.first(where: { $0.id == surfaceID }),
                      let oldNode = controller.surfaceTree.root?.node(view: oldView) else {
                    throw GhosttyAttachTabHostError.placeholderUnavailable
                }
                let newTree = try controller.surfaceTree.replacing(node: oldNode, with: .leaf(view: newView))
                // Assigned directly (not via `replaceSurfaceTree`, which always
                // registers an undo action -- even with a nil `undoAction` --
                // and would let "undo" restore the old tree, resurrecting the
                // dead `oldView` (the surface that just exited) into a live
                // split). Focus is moved the same way `replaceSurfaceTree`
                // does it for its `newView` argument.
                controller.surfaceTree = newTree
                controller.focusedSurface = newView
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: newView, from: oldView)
                }
                controller.leoSession?.fillPlaceholder(surfaceID: surfaceID)
                // Routed through `close(_:)` -- not a direct
                // `attachments.removeValue(forKey:)` -- so the coordinator's
                // `.closed` handling (identityByHandle/handlesByIdentity/
                // inactive cleanup) actually runs for the replaced handle.
                // Safe regardless of ordering relative to the new handle:
                // `close(_:)` only touches `attachments`/the lifecycle
                // continuation, and `previousHandles` is keyed by
                // `oldView.id` (`surfaceID`), never the new handle's key
                // (`newView.id`), so there is no risk of it clobbering the
                // surface just installed above.
                let previousHandles = attachments.keys.filter { $0.surfaceID == surfaceID }
                previousHandles.forEach { close($0) }
            } else {
            // Assigned directly (not via `replaceSurfaceTree`, which always
            // registers an undo action -- even with a nil `undoAction` -- and
            // would let "undo" reopen a placeholder that was never a real
            // close). The `didSet` observer this triggers is the normal
            // non-init path, so `surfaceTreeDidChange`'s empty-tree-closes-
            // window guard doesn't fire here (this transition is empty -> non-empty).
            controller.surfaceTree = SplitTree(view: newView)
            controller.focusedSurface = newView
            controller.focusSurface(newView)
            // `windowDidLoad` ran once already, with no surface, so its
            // default-size logic (which depends on `focusedSurface`) was a
            // no-op -- and the placeholder-creation undo (a plain "close if
            // still empty") no longer applies now that there's real content.
            controller.leoApplyInitialSize()
            controller.leoRegisterFilledPlaceholderUndo()
            }

            let handle = try register(controller, surface: newView)
            Self.logger.log("fillPlaceholder requestID=\(requestID.uuidString, privacy: .public) result=success")
            return handle
        } catch {
            Self.logger.log("fillPlaceholder requestID=\(requestID.uuidString, privacy: .public) result=failure error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func focus(_ handle: AttachmentHandle) {
        guard let attachment = attachments[handle], let controller = attachment.controller, let surface = attachment.surface,
              controller.surfaceTree.contains(surface), let window = controller.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        Ghostty.moveFocus(to: surface)
    }

    func rebirthPlaceholder(for handle: AttachmentHandle) {
        guard let attachment = attachments[handle], let controller = attachment.controller,
              let surface = attachment.surface, controller.surfaceTree.contains(surface) else { return }
        controller.leoSession?.rebirthPlaceholder(surfaceID: handle.surfaceID)
        Ghostty.moveFocus(to: surface)
    }

    func discardEmptyPlaceholder(origin: LeoWindowID) {
        guard let controller = registry.controller(for: origin),
              Self.startScreenState(of: controller)?.isUntouched == true else { return }
        Self.logger.log("discardEmptyPlaceholder origin=\(origin.rawValue.uuidString, privacy: .public)")
        // The same close an emptied tree takes -- no undo: there is
        // nothing in a blank start screen to bring back. On the next turn:
        // a sidebar click (B-050) asks from inside that window's own mouse
        // event, which AppKit is still delivering to it.
        DispatchQueue.main.async { [weak controller] in
            guard let controller, Self.startScreenState(of: controller)?.isUntouched == true else { return }
            controller.window?.close()
        }
    }

    /// `nil` for a window with no Leo session (no start screen at all).
    /// The editor and browser count by what they show: their pane views
    /// (`editorPane`, `browserPane`) exist in every window once its split
    /// view is built, open or not.
    private static func startScreenState(of controller: TerminalController) -> LeoStartScreenState? {
        guard let session = controller.leoSession else { return nil }
        return LeoStartScreenState(
            isUnfilledPlaceholder: controller.leoIsUnfilledPlaceholder,
            hasTerminal: !controller.surfaceTree.isEmpty,
            isEditorOpen: session.editor.isOpen,
            isBrowserOpen: session.browser.isOpen
        )
    }

    func isOpen(_ handle: AttachmentHandle) -> Bool {
        guard let attachment = attachments[handle], let controller = attachment.controller, let surface = attachment.surface else { return false }
        return controller.window != nil && controller.surfaceTree.contains(surface)
    }

    /// Titles `handle`'s surface after its agent (B-052). The name stays on
    /// that surface -- through the exited placeholder -- until the slot is
    /// refilled with a new surface.
    func setAgentName(_ handle: AttachmentHandle, name: String) {
        attachments[handle]?.surface?.leoAgentName = name
    }

    /// Starts from the inherited config stashed for this request (if any --
    /// see `LeoRequestConfigStore`), then overlays `command`/`workingDirectory`
    /// /a cleared `environmentVariables` on top exactly as before, but only
    /// for an actual attach (`command` non-empty). A plain shell
    /// (`command == ""`) has nothing to overlay, so the inherited config
    /// (or a fresh default if there wasn't one) is used as-is -- clearing
    /// its `workingDirectory`/`environmentVariables` unconditionally would
    /// have silently dropped the very thing this is meant to preserve.
    private func configuration(command: String, workingDirectory: String?, requestID: UUID) -> Ghostty.SurfaceConfiguration {
        var configuration = requestConfigStore.consume(for: requestID) ?? Ghostty.SurfaceConfiguration()
        guard !command.isEmpty else { return configuration }
        configuration.command = command
        configuration.workingDirectory = workingDirectory
        configuration.environmentVariables = [:]
        return configuration
    }

    /// Registers `surface` -- the exact surface the caller just created --
    /// as the destination for a new `AttachmentHandle`. Deliberately takes
    /// the surface explicitly rather than falling back to
    /// `controller.focusedSurface ?? controller.surfaceTree.first`: for a
    /// split, the controller may already own other surfaces, and focus can
    /// lag the insertion by a runloop turn, so either fallback can resolve
    /// to the wrong (pre-existing) surface.
    private func register(_ controller: TerminalController, surface: Ghostty.SurfaceView) throws -> AttachmentHandle {
        guard let session = controller.leoSession, controller.surfaceTree.contains(surface) else {
            throw GhosttyAttachTabHostError.surfaceUnavailable
        }
        let handle = AttachmentHandle(surfaceID: surface.id, windowID: session.id)
        let attachment = Attachment(controller: controller, surface: surface)
        attachments[handle] = attachment

        controller.$surfaceTree
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.reconcile(handle) }
            }
            .store(in: &attachment.cancellables)
        surface.$childExitedMessage
            .dropFirst()
            .compactMap { $0 }
            .prefix(1)
            .sink { [weak self] _ in self?.continuation.yield(.processExited(handle)) }
            .store(in: &attachment.cancellables)
        if let window = controller.window {
            attachment.closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.close(handle) } }
        }
        // Focus may already be on the new surface (no later notification).
        DispatchQueue.main.async { [weak self] in self?.reportFocus() }
        return handle
    }

    private func reconcile(_ handle: AttachmentHandle) {
        guard !isOpen(handle) else { return }
        close(handle)
    }

    private func close(_ handle: AttachmentHandle) {
        guard attachments.removeValue(forKey: handle) != nil else { return }
        continuation.yield(.closed(handle))
        reportFocus()
    }
}

private enum GhosttyAttachTabHostError: Error, LocalizedError {
    case originWindowClosed, noTerminalWindow, surfaceUnavailable
    case splitSourceUnavailable, cannotOpenSplit, placeholderNotEmpty, placeholderUnavailable

    var errorDescription: String? {
        switch self {
        case .originWindowClosed: "The originating terminal window is closed"
        case .noTerminalWindow: "No terminal window is available"
        case .surfaceUnavailable: "The new terminal surface is unavailable"
        case .splitSourceUnavailable: "The surface to split from is no longer available"
        case .cannotOpenSplit: "Ghostty could not open a new split"
        case .placeholderNotEmpty: "The window is not an empty placeholder"
        case .placeholderUnavailable: "The placeholder surface is unavailable"
        }
    }
}

@MainActor private final class Attachment {
    weak var controller: TerminalController?
    weak var surface: Ghostty.SurfaceView?
    var cancellables: Set<AnyCancellable> = []
    var closeObserver: NSObjectProtocol?

    init(controller: TerminalController, surface: Ghostty.SurfaceView) {
        self.controller = controller
        self.surface = surface
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }
}
