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
    /// B-056: what each window keeps attached but hidden.
    private lazy var live = LeoLiveSurfaces(
        isAgent: { [weak self] in self?.isAttach($0) ?? false },
        isTerminalRow: { [weak self] in self?.isTerminalRow($0) ?? false },
        isClient: { [weak self] in self?.isLiveAttach($0) ?? false },
        letGo: { [weak self] in self?.closeHandles(in: $0) }
    )
    private var hiddenExitObservers: [NSObjectProtocol] = []
    private var windowCloseObservers: [LeoWindowID: NSObjectProtocol] = [:]

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
        observeHiddenSurfaceExits()
    }

    deinit {
        continuation.finish()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hiddenExitObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowCloseObservers.values.forEach { NotificationCenter.default.removeObserver($0) }
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
        let handle = try register(controller, surface: newView, isAttach: !command.isEmpty, isTerminalRow: command.isEmpty)
        retire(displaced, from: controller)
        selectShownTerminal(in: controller)
        Self.logger.log("showInContent requestID=\(requestID.uuidString, privacy: .public) replaced=\(Array(displaced).count)")
        return handle
    }

    /// B-056: shows the hidden tree holding `handle`'s surface again, in
    /// place of what its window shows -- the same `Ghostty.SurfaceView`s,
    /// so no new tmux client, and scrollback, scroll position and
    /// selection are as they were left. `false` when it isn't hidden (or
    /// nothing in it is still attached, and it was let go).
    func reveal(_ handle: AttachmentHandle) -> Bool {
        guard let attachment = attachments[handle], let controller = attachment.controller,
              let surface = attachment.surface, controller.window != nil,
              let tree = live.take(treeHolding: surface, in: handle.windowID) else { return false }
        let displaced = controller.leoReplaceContent(with: tree, focusing: surface)
        retire(displaced, from: controller)
        reportExitedPanes(in: tree)
        selectShownTerminal(in: controller)
        Self.logger.log("reveal window=\(handle.windowID.rawValue.uuidString, privacy: .public) surfaces=\(Array(tree).count)")
        return true
    }

    /// B-056: lets go of the hidden tree holding `handle`'s surface; its
    /// tmux clients detach and its handles close. Shown content is left
    /// alone.
    func release(_ handle: AttachmentHandle) {
        guard let surface = attachments[handle]?.surface else { return }
        live.release(treeHolding: surface, in: handle.windowID)
    }

    /// B-057: a terminal row's shell closed (⌘W, `exit`) -- whether it is
    /// still on screen or not: its close lands a turn late, or once a
    /// confirm is answered, so a reveal may have hidden it meanwhile.
    /// Shown, it closes on screen (`closeShownTerminal`); hidden, it is
    /// let go from the keep and nothing on screen changes; already gone
    /// (Ghostty's close observer got there first), nothing happens. Any
    /// order of the two ends the same.
    func closeTerminal(_ handle: AttachmentHandle) {
        guard let (controller, surface) = liveSurface(handle) else { return }
        if controller.surfaceTree.contains(surface) { return closeShownTerminal(handle, surface: surface, in: controller) }
        guard live.discardKept(treeHolding: surface, in: handle.windowID) else { return }
        Self.logger.log("closeTerminal window=\(handle.windowID.rawValue.uuidString, privacy: .public) hidden=true")
    }

    /// The shown row's shell closed. Alone in the window: the nearest
    /// neighbouring row with a live hidden shell takes its place -- the
    /// same surface -- or, with none, the start screen does; the window
    /// stays. (A neighbour whose shell ended is let go on the way.) What
    /// closed is let go at once: its surfaces free their ptys, and its
    /// handles (so its row) close. With a split beside it, only its own
    /// pane closes (`closeShownPane`).
    private func closeShownTerminal(_ handle: AttachmentHandle, surface: Ghostty.SurfaceView, in controller: TerminalController) {
        guard case .leaf(let root)? = controller.surfaceTree.root, root === surface else {
            return closeShownPane(handle, surface: surface, in: controller)
        }
        guard let terminals = controller.leoSession?.terminals else { return }
        let closing = controller.surfaceTree
        if let (tree, focus) = neighbourTree(of: handle, in: terminals) {
            controller.leoReplaceContent(with: tree, focusing: focus)
            reportExitedPanes(in: tree)
        } else {
            controller.leoShowStartScreen()
        }
        closing.forEach { controller.leoSession?.fillPlaceholder(surfaceID: $0.id) }
        closeHandles(in: closing)
        selectShownTerminal(in: controller)
        Self.logger.log("closeTerminal window=\(handle.windowID.rawValue.uuidString, privacy: .public) neighbour=\(!controller.surfaceTree.isEmpty)")
    }

    /// The shown row's shell closed with a split (⌘D) beside it: only its
    /// own pane closes, as a split's close does (undoable, focus moving
    /// on), and its handle -- so its row -- with it. What is split beside
    /// it stays: a busy shell there is never closed without asking.
    private func closeShownPane(_ handle: AttachmentHandle, surface: Ghostty.SurfaceView, in controller: TerminalController) {
        guard let node = controller.surfaceTree.root?.node(view: surface) else { return }
        controller.closeSurface(node, withConfirmation: false)
        closeHandles(in: SplitTree(view: surface))
        selectShownTerminal(in: controller)
        Self.logger.log("closeTerminal window=\(handle.windowID.rawValue.uuidString, privacy: .public) pane=true")
    }

    /// The nearest neighbouring row's hidden tree that can be shown,
    /// taken to be shown, and the surface to focus in it.
    private func neighbourTree(
        of handle: AttachmentHandle,
        in terminals: LeoWindowTerminals
    ) -> (SplitTree<Ghostty.SurfaceView>, Ghostty.SurfaceView)? {
        for neighbour in terminals.list.neighbours(of: handle.surfaceID) {
            guard let surface = attachments[AttachmentHandle(surfaceID: neighbour, windowID: handle.windowID)]?.surface,
                  let tree = live.take(treeHolding: surface, in: handle.windowID) else { continue }
            return (tree, surface)
        }
        return nil
    }

    /// Whether closing `window` would kill a busy shell it keeps hidden
    /// for a terminal row (a hidden agent detaches losslessly).
    func hiddenTerminalsNeedConfirmQuit(in window: LeoWindowID) -> Bool {
        live.keptSurfaces(in: window).contains { $0.needsConfirmQuit }
    }

    func selectShownTerminal(in window: LeoWindowID) {
        let controller = attachments.first { $0.key.windowID == window }?.value.controller ?? registry.controller(for: window)
        guard let controller else { return }
        selectShownTerminal(in: controller)
    }

    /// The window's sidebar selects the terminal row it now shows, or --
    /// showing an agent, or the start screen -- none.
    private func selectShownTerminal(in controller: TerminalController) {
        guard let terminals = controller.leoSession?.terminals else { return }
        terminals.select(controller.surfaceTree.first { terminals.contains($0.id) }?.id)
    }

    func confirmReplacingContent(origin: LeoWindowID) async -> Bool {
        guard let controller = registry.controller(for: origin) else { return true }
        let shown = controller.surfaceTree.map {
            LeoContentReplacement.Shown(
                isAgent: $0.leoAgentName != nil, isTerminalRow: isTerminalRow($0), needsConfirmQuit: $0.needsConfirmQuit
            )
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

    /// What leaves the content area on a switch goes into the window's
    /// live pool (B-056), and whatever no longer fits -- or holds no live
    /// attach, like a plain shell -- is let go: nothing holds its surfaces
    /// then, so each frees its Ghostty surface and pty, an attach's tmux
    /// client detaches, and its handle is reported `.closed`. Hidden
    /// exited panes stop counting as placeholders (`reveal` reports them
    /// again).
    private func retire(_ displaced: SplitTree<Ghostty.SurfaceView>, from controller: TerminalController) {
        displaced.forEach { controller.leoSession?.fillPlaceholder(surfaceID: $0.id) }
        guard let window = controller.leoSession?.id else { return }
        live.hide(displaced, in: window, showing: controller.surfaceTree)
    }

    /// A new attach in `controller`'s content area may leave its window
    /// over capacity; the least recently viewed hidden trees go.
    private func trimLivePool(of controller: TerminalController) {
        guard let window = controller.leoSession?.id else { return }
        live.trim(window, showing: controller.surfaceTree)
    }

    /// A pane that exited while hidden got no child-exited message (Ghostty
    /// shows none off screen), and one that exited while shown lost its
    /// placeholder when hidden: either way it is reported again now.
    private func reportExitedPanes(in tree: SplitTree<Ghostty.SurfaceView>) {
        for (handle, attachment) in attachments where attachment.isAttach {
            guard let surface = attachment.surface, tree.contains(where: { $0 === surface }), surface.processExited else { continue }
            continuation.yield(.processExited(handle))
        }
    }

    /// An agent attach surface (live or exited), not a plain shell.
    private func isAttach(_ surface: Ghostty.SurfaceView) -> Bool {
        attachments.values.contains { $0.isAttach && $0.surface === surface }
    }

    /// A terminal row's own shell (B-057).
    private func isTerminalRow(_ surface: Ghostty.SurfaceView) -> Bool {
        attachments.values.contains { $0.isTerminalRow && $0.surface === surface }
    }

    /// A tmux client: a live attach surface (not a plain shell, not exited).
    private func isLiveAttach(_ surface: Ghostty.SurfaceView) -> Bool {
        !surface.processExited && isAttach(surface)
    }

    /// The handles of every surface in `tree` (which the pool let go) close.
    private func closeHandles(in tree: SplitTree<Ghostty.SurfaceView>) {
        let handles = attachments.filter { entry in tree.contains { $0 === entry.value.surface } }.keys
        handles.forEach(close)
    }

    /// A hidden surface's process ending reaches no controller: Ghostty
    /// shows no exit message off screen (Leo posts
    /// `.leoWindowlessChildExited` instead), and a close request (when
    /// Ghostty closes on exit) names a surface in no tree. The host takes
    /// both -- on the next turn: both arrive from inside libghostty's
    /// handling of that very surface, which must not be freed under it.
    ///
    /// Whose a close request is, is decided when it arrives: a terminal
    /// row's shell hidden then gets no controller's close, so -- its
    /// process having ended -- its row closes the way ⌘W's does
    /// (`closeRequested`), which holds whether a reveal has shown it by the
    /// next turn, it is still hidden, or it is already gone. Anything else
    /// hidden is the pool's.
    private func observeHiddenSurfaceExits() {
        let center = NotificationCenter.default
        hiddenExitObservers = [
            center.addObserver(forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main) { [weak self] notification in
                guard let surface = notification.object as? Ghostty.SurfaceView else { return }
                let processEnded = notification.userInfo?["process_alive"] as? Bool == false
                MainActor.assumeIsolated {
                    let hiddenRow = self?.hiddenTerminalRow(surface)
                    DispatchQueue.main.async { [weak surface] in
                        guard let surface else { return }
                        self?.handleCloseRequest(of: surface, hiddenRow: hiddenRow, processEnded: processEnded)
                    }
                }
            },
            center.addObserver(forName: .leoWindowlessChildExited, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.live.dropDead() }
            },
        ]
    }

    /// A close request for `surface`, a turn after it arrived. Not a hidden
    /// row's: the pool's (which leaves the rows' keep alone). A hidden
    /// row's whose process lives -- nothing reaches a hidden shell to ask
    /// that -- is left be: only its row's close or its exit ends a kept
    /// shell (D-111).
    private func handleCloseRequest(of surface: Ghostty.SurfaceView, hiddenRow: AttachmentHandle?, processEnded: Bool) {
        guard let hiddenRow else {
            live.surfaceClosed(surface)
            return
        }
        guard processEnded else { return }
        requestClose(of: hiddenRow)
    }

    /// The terminal row whose shell `surface` is, while no controller
    /// shows it.
    private func hiddenTerminalRow(_ surface: Ghostty.SurfaceView) -> AttachmentHandle? {
        guard let handle = attachments.first(where: { $0.value.isTerminalRow && $0.value.surface === surface })?.key,
              !isShown(handle) else { return nil }
        return handle
    }

    /// Closes `handle`'s row as its controller's close does: through its
    /// window's terminals, so the coordinator hears of it (nothing, once
    /// the row is gone).
    private func requestClose(of handle: AttachmentHandle) {
        attachments[handle]?.controller?.leoSession?.terminals.closeRequested(handle.surfaceID)
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
        let handle = try register(controller, surface: surface, isAttach: !command.isEmpty, isTerminalRow: command.isEmpty)
        selectShownTerminal(in: controller)
        return handle
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
            let handle = try register(controller, surface: newView, isAttach: !command.isEmpty)
            trimLivePool(of: controller)
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
            let isFirstContent = !controller.leoHasShownContent
            controller.surfaceTree = SplitTree(view: newView)
            controller.focusedSurface = newView
            controller.focusSurface(newView)
            if isFirstContent {
                // `windowDidLoad` ran once already, with no surface, so its
                // default-size logic (which depends on `focusedSurface`) was
                // a no-op -- and the placeholder-creation undo (a plain "close
                // if still empty") no longer applies now that there's real
                // content.
                controller.leoApplyInitialSize()
                controller.leoRegisterFilledPlaceholderUndo()
            } else {
                // B-057: a start screen its last terminal row left keeps
                // the window's size.
                controller.leoMarkFilled()
            }
            }

            let handle = try register(controller, surface: newView, isAttach: !command.isEmpty, isTerminalRow: surfaceID == nil && command.isEmpty)
            trimLivePool(of: controller)
            selectShownTerminal(in: controller)
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
            // A start screen the window's last terminal row left isn't new.
            isUnfilledPlaceholder: controller.leoIsUnfilledPlaceholder && !controller.leoHasShownContent,
            hasTerminal: !controller.surfaceTree.isEmpty,
            isEditorOpen: session.editor.isOpen,
            isBrowserOpen: session.browser.isOpen
        )
    }

    /// Shown, or hidden in its window's live pool (B-056): either way its
    /// tmux client is attached.
    func isOpen(_ handle: AttachmentHandle) -> Bool {
        guard let (controller, surface) = liveSurface(handle) else { return false }
        return controller.surfaceTree.contains(surface) || live.contains(surface, in: handle.windowID)
    }

    /// What `window` keeps hidden (tests and diagnostics).
    func hiddenSurfaces(in window: LeoWindowID) -> [Ghostty.SurfaceView] { live.hiddenSurfaces(in: window) }

    func isShown(_ handle: AttachmentHandle) -> Bool {
        guard let (controller, surface) = liveSurface(handle) else { return false }
        return controller.surfaceTree.contains(surface)
    }

    private func liveSurface(_ handle: AttachmentHandle) -> (TerminalController, Ghostty.SurfaceView)? {
        guard let attachment = attachments[handle], let controller = attachment.controller,
              let surface = attachment.surface, controller.window != nil else { return nil }
        return (controller, surface)
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
    ///
    /// B-057: a plain shell shown as a window's whole content is a terminal
    /// row in that window's sidebar, titled by its terminal.
    private func register(
        _ controller: TerminalController,
        surface: Ghostty.SurfaceView,
        isAttach: Bool,
        isTerminalRow: Bool = false
    ) throws -> AttachmentHandle {
        guard let session = controller.leoSession, controller.surfaceTree.contains(surface) else {
            throw GhosttyAttachTabHostError.surfaceUnavailable
        }
        let handle = AttachmentHandle(surfaceID: surface.id, windowID: session.id)
        let attachment = Attachment(controller: controller, surface: surface, isAttach: isAttach, isTerminalRow: isTerminalRow)
        attachments[handle] = attachment
        if isTerminalRow { addTerminalRow(surface, to: session.terminals, cancellables: &attachment.cancellables) }

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
        observeClose(of: controller, as: session.id)
        // Focus may already be on the new surface (no later notification).
        DispatchQueue.main.async { [weak self] in self?.reportFocus() }
        return handle
    }

    /// The row follows its terminal's title as it changes.
    private func addTerminalRow(
        _ surface: Ghostty.SurfaceView,
        to terminals: LeoWindowTerminals,
        cancellables: inout Set<AnyCancellable>
    ) {
        let id = surface.id
        terminals.add(id, title: surface.title)
        surface.$title
            .removeDuplicates()
            .sink { [weak terminals] in terminals?.retitle(id, to: $0) }
            .store(in: &cancellables)
    }

    private func reconcile(_ handle: AttachmentHandle) {
        guard !isOpen(handle) else { return }
        close(handle)
    }

    /// One close hook per window, installed with its first handle.
    private func observeClose(of controller: TerminalController, as windowID: LeoWindowID) {
        guard windowCloseObservers[windowID] == nil, let window = controller.window else { return }
        windowCloseObservers[windowID] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.windowWillClose(windowID) } }
    }

    /// Every handle the window held closes, and its hidden trees go with
    /// it: no tmux client outlives its window. Keyed by window, so nothing
    /// here depends on its (weakly held) surfaces still being alive.
    private func windowWillClose(_ windowID: LeoWindowID) {
        if let observer = windowCloseObservers.removeValue(forKey: windowID) {
            NotificationCenter.default.removeObserver(observer)
        }
        attachments.keys.filter { $0.windowID == windowID }.forEach(close)
        live.releaseAll(in: windowID)
    }

    private func close(_ handle: AttachmentHandle) {
        guard let attachment = attachments.removeValue(forKey: handle) else { return }
        if attachment.isTerminalRow { removeTerminalRow(handle, of: attachment) }
        continuation.yield(.closed(handle))
        reportFocus()
    }

    /// A closed shell's row goes. Selected -- a hidden row arrowed onto,
    /// closed or exited -- the sidebar selects what the window shows
    /// instead: its row, or none so the agent's selection shows (B-071,
    /// D-116).
    private func removeTerminalRow(_ handle: AttachmentHandle, of attachment: Attachment) {
        guard let controller = attachment.controller ?? registry.controller(for: handle.windowID),
              let terminals = controller.leoSession?.terminals else { return }
        let wasSelected = terminals.selection == handle.surfaceID
        terminals.remove(handle.surfaceID)
        if wasSelected { selectShownTerminal(in: controller) }
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
    /// An agent attach (a tmux client), not a plain shell.
    let isAttach: Bool
    /// A terminal row's own shell (B-057).
    let isTerminalRow: Bool
    var cancellables: Set<AnyCancellable> = []

    init(controller: TerminalController, surface: Ghostty.SurfaceView, isAttach: Bool, isTerminalRow: Bool) {
        self.controller = controller
        self.surface = surface
        self.isAttach = isAttach
        self.isTerminalRow = isTerminalRow
    }
}
