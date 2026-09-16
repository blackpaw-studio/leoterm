import AppKit
import Combine
import GhosttyKit

@MainActor final class GhosttyAttachTabHost: AttachTabHost {
    let lifecycleEvents: AsyncStream<AttachLifecycleEvent>
    private let continuation: AsyncStream<AttachLifecycleEvent>.Continuation
    private let registry: LeoWindowSessionRegistry
    private var attachments: [AttachmentHandle: Attachment] = [:]

    init(registry: LeoWindowSessionRegistry) {
        self.registry = registry
        (lifecycleEvents, continuation) = AsyncStream.makeStream()
    }

    deinit { continuation.finish() }

    func openTab(command: String, workingDirectory: String?, from origin: LeoWindowID) throws -> AttachmentHandle {
        guard let source = registry.controller(for: origin) else { throw GhosttyAttachTabHostError.originWindowClosed }
        guard let controller = TerminalController.newTab(
            source.ghostty,
            from: source.window,
            withBaseConfig: configuration(command: command, workingDirectory: workingDirectory)
        ) else { throw GhosttyAttachTabHostError.cannotOpenTab }
        return try register(controller)
    }

    func openWindow(command: String, workingDirectory: String?) throws -> AttachmentHandle {
        guard let ghostty = TerminalController.preferredParent?.ghostty else { throw GhosttyAttachTabHostError.noTerminalWindow }
        return try register(TerminalController.newWindow(ghostty, withBaseConfig: configuration(command: command, workingDirectory: workingDirectory)))
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

    private func configuration(command: String, workingDirectory: String?) -> Ghostty.SurfaceConfiguration {
        var configuration = Ghostty.SurfaceConfiguration()
        configuration.command = command
        configuration.workingDirectory = workingDirectory
        configuration.environmentVariables = [:]
        return configuration
    }

    private func register(_ controller: TerminalController) throws -> AttachmentHandle {
        _ = controller.window
        guard let session = controller.leoSession, let surface = controller.focusedSurface ?? controller.surfaceTree.first else {
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

    var errorDescription: String? {
        switch self {
        case .originWindowClosed: "The originating terminal window is closed"
        case .cannotOpenTab: "Ghostty could not open a new tab"
        case .noTerminalWindow: "No terminal window is available"
        case .surfaceUnavailable: "The new terminal surface is unavailable"
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
