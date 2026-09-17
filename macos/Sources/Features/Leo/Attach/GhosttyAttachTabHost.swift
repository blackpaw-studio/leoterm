import AppKit
import Combine
import GhosttyKit

@MainActor final class GhosttyAttachTabHost: AttachTabHost {
    let lifecycleEvents: AsyncStream<AttachLifecycleEvent>
    private let continuation: AsyncStream<AttachLifecycleEvent>.Continuation
    private let registry: LeoWindowSessionRegistry
    private let requestConfigStore: LeoRequestConfigStore
    private var attachments: [AttachmentHandle: Attachment] = [:]

    init(registry: LeoWindowSessionRegistry, requestConfigStore: LeoRequestConfigStore) {
        self.registry = registry
        self.requestConfigStore = requestConfigStore
        (lifecycleEvents, continuation) = AsyncStream.makeStream()
    }

    deinit { continuation.finish() }

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
        guard let controller = registry.controller(for: origin) else { throw GhosttyAttachTabHostError.originWindowClosed }
        guard let sourceView = controller.surfaceTree.first(where: { $0.id == sourceSurface }) else {
            throw GhosttyAttachTabHostError.splitSourceUnavailable
        }
        guard let newView = controller.leoCreateSplit(
            at: sourceView,
            direction: leoSplitTreeDirection(for: direction),
            baseConfig: configuration(command: command, workingDirectory: workingDirectory, requestID: requestID)
        ) else { throw GhosttyAttachTabHostError.cannotOpenSplit }
        return try register(controller, surface: newView)
    }

    /// Replaces the origin window's empty surface tree with a freshly
    /// created attach surface. Refuses (throws) if the tree is not empty --
    /// there is nothing to "fill" otherwise, and this must never clobber a
    /// live split.
    func fillPlaceholder(command: String, workingDirectory: String?, origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle {
        guard let controller = registry.controller(for: origin) else { throw GhosttyAttachTabHostError.originWindowClosed }
        guard controller.surfaceTree.isEmpty else { throw GhosttyAttachTabHostError.placeholderNotEmpty }
        guard let ghosttyApp = controller.ghostty.app else { throw GhosttyAttachTabHostError.noTerminalWindow }

        let newView = Ghostty.SurfaceView(
            ghosttyApp,
            baseConfig: configuration(command: command, workingDirectory: workingDirectory, requestID: requestID)
        )
        guard newView.surface != nil else { throw GhosttyAttachTabHostError.surfaceUnavailable }

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

        return try register(controller, surface: newView)
    }

    func focus(_ handle: AttachmentHandle) {
        guard let attachment = attachments[handle], let controller = attachment.controller, let surface = attachment.surface,
              controller.surfaceTree.contains(surface), let window = controller.window else { return }
        window.tabGroup?.selectedWindow = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
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
        return handle
    }

    private func reconcile(_ handle: AttachmentHandle) {
        guard !isOpen(handle) else { return }
        close(handle)
    }

    private func close(_ handle: AttachmentHandle) {
        guard attachments.removeValue(forKey: handle) != nil else { return }
        continuation.yield(.closed(handle))
    }
}

private enum GhosttyAttachTabHostError: Error, LocalizedError {
    case originWindowClosed, cannotOpenTab, noTerminalWindow, surfaceUnavailable
    case splitSourceUnavailable, cannotOpenSplit, placeholderNotEmpty

    var errorDescription: String? {
        switch self {
        case .originWindowClosed: "The originating terminal window is closed"
        case .cannotOpenTab: "Ghostty could not open a new tab"
        case .noTerminalWindow: "No terminal window is available"
        case .surfaceUnavailable: "The new terminal surface is unavailable"
        case .splitSourceUnavailable: "The surface to split from is no longer available"
        case .cannotOpenSplit: "Ghostty could not open a new split"
        case .placeholderNotEmpty: "The window is not an empty placeholder"
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
