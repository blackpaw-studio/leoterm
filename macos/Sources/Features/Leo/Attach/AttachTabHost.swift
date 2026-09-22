import Foundation

struct LeoWindowID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

struct AttachmentHandle: Hashable, Sendable {
    let surfaceID: UUID
    let windowID: LeoWindowID
}

enum AttachLifecycleEvent: Equatable, Sendable {
    case closed(AttachmentHandle)
    case titleChanged(AttachmentHandle, String)
    case processExited(AttachmentHandle)
    /// The attachment (if any) that is now the focused surface of the key
    /// window, or `nil` when focus left every attachment (another surface,
    /// no key window, app inactive).
    case focusChanged(AttachmentHandle?)
}

extension Notification.Name {
    /// Posted by `BaseTerminalController` whenever its `focusedSurface` is
    /// assigned (object: the controller).
    static let leoFocusedSurfaceDidChange = Notification.Name("studio.blackpaw.leo.focusedSurfaceDidChange")
}

@MainActor protocol AttachTabHost: AnyObject {
    var lifecycleEvents: AsyncStream<AttachLifecycleEvent> { get }
    /// The attachment that is the focused surface of the key window of the
    /// active app, if any. Changes are reported as `.focusChanged`.
    var focusedHandle: AttachmentHandle? { get }
    /// `requestID` looks up the inherited `Ghostty.SurfaceConfiguration`
    /// (if any) from `LeoRequestConfigStore` -- see
    /// `GhosttyAttachTabHost.configuration(command:workingDirectory:requestID:)`.
    func openTab(command: String, workingDirectory: String?, from origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle
    func openWindow(command: String, workingDirectory: String?, requestID: UUID) throws -> AttachmentHandle
    /// Always creates a new split (tmux allows multiple clients on the same
    /// agent, so -- unlike `.tab` -- this is never a reuse/focus path).
    func openSplit(
        command: String,
        workingDirectory: String?,
        origin: LeoWindowID,
        sourceSurface: UUID,
        direction: LeoSplitDirection,
        requestID: UUID
    ) throws -> AttachmentHandle
    /// Replaces the origin window's empty placeholder surface tree with the
    /// attach surface. Always creates -- there is nothing to reuse.
    func fillPlaceholder(command: String, workingDirectory: String?, origin: LeoWindowID, surfaceID: UUID?, requestID: UUID) throws -> AttachmentHandle
    func rebirthPlaceholder(for handle: AttachmentHandle)
    func focus(_ handle: AttachmentHandle)
    func isOpen(_ handle: AttachmentHandle) -> Bool
    func setTitleSeed(_ handle: AttachmentHandle, title: String?)
}
