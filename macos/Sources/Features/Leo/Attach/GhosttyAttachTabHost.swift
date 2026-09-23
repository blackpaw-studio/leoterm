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
    private var reportedFocus: AttachmentHandle?
    private(set) var focusReportCount = 0

    init(registry: LeoWindowSessionRegistry, requestConfigStore: LeoRequestConfigStore) {
        self.registry = registry
        self.requestConfigStore = requestConfigStore
        (lifecycleEvents, continuation) = AsyncStream.makeStream()
        observeFocus()
    }

    deinit {
        continuation.finish()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Key window -> its selected tab's controller -> `focusedSurface`, so a
    /// focused split counts. `nil` while the app is inactive.
    var focusedHandle: AttachmentHandle? {
        guard NSApp.isActive, let controller = NSApp.keyWindow?.windowController as? BaseTerminalController,
              let surface = controller.focusedSurface else { return nil }
        return attachments.first { $0.value.controller === controller && $0.value.surface === surface }?.key
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
    }

    private func reportFocus() {
        let handle = focusedHandle
        guard handle != reportedFocus else { return }
        reportedFocus = handle
        focusReportCount += 1
        continuation.yield(.focusChanged(handle))
    }

    func openTab(command: String, workingDirectory: String?, from origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle {
        guard let source = registry.controller(for: origin) else { throw GhosttyAttachTabHostError.originWindowClosed }
        guard let controller = TerminalController.newTab(
            source.ghostty,
            from: source.window,
            withBaseConfig: configuration(command: command, workingDirectory: workingDirectory, requestID: requestID)
        ) else { throw GhosttyAttachTabHostError.cannotOpenTab }
        guard let surface = controller.surfaceTree.first else { throw GhosttyAttachTabHostError.surfaceUnavailable }
        return try register(controller, surface: surface)
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
            guard let ghosttyApp = controller.ghostty.app else { throw GhosttyAttachTabHostError.noTerminalWindow }

            let newView = Ghostty.SurfaceView(
                ghosttyApp,
                baseConfig: configuration(command: command, workingDirectory: workingDirectory, requestID: requestID)
            )
            guard newView.surface != nil else { throw GhosttyAttachTabHostError.surfaceUnavailable }

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
        window.tabGroup?.selectedWindow = window
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

    func isOpen(_ handle: AttachmentHandle) -> Bool {
        guard let attachment = attachments[handle], let controller = attachment.controller, let surface = attachment.surface else { return false }
        return controller.window != nil && controller.surfaceTree.contains(surface)
    }

    func setTitleSeed(_ handle: AttachmentHandle, title: String?) {
        guard let controller = attachments[handle]?.controller else { return }
        if title == nil {
            guard controller.titleOverride == attachments[handle]?.titleSeed else { return }
        } else {
            attachments[handle]?.titleSeed = title
        }
        controller.titleOverride = title
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
        surface.$title
            .dropFirst()
            .filter { !$0.isEmpty }
            .sink { [weak self] title in self?.continuation.yield(.titleChanged(handle, title)) }
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
    case originWindowClosed, cannotOpenTab, noTerminalWindow, surfaceUnavailable
    case splitSourceUnavailable, cannotOpenSplit, placeholderNotEmpty, placeholderUnavailable

    var errorDescription: String? {
        switch self {
        case .originWindowClosed: "The originating terminal window is closed"
        case .cannotOpenTab: "Ghostty could not open a new tab"
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
    var titleSeed: String?
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
