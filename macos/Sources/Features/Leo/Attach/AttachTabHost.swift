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
}

@MainActor protocol AttachTabHost: AnyObject {
    var lifecycleEvents: AsyncStream<AttachLifecycleEvent> { get }
    func openTab(command: String, workingDirectory: String?, from origin: LeoWindowID) throws -> AttachmentHandle
    func openWindow(command: String, workingDirectory: String?) throws -> AttachmentHandle
    /// Always creates a new split (tmux allows multiple clients on the same
    /// agent, so -- unlike `.tab` -- this is never a reuse/focus path).
    func openSplit(
        command: String,
        workingDirectory: String?,
        origin: LeoWindowID,
        sourceSurface: UUID,
        direction: LeoSplitDirection
    ) throws -> AttachmentHandle
    /// Replaces the origin window's empty placeholder surface tree with the
    /// attach surface. Always creates -- there is nothing to reuse.
    func fillPlaceholder(command: String, workingDirectory: String?, origin: LeoWindowID) throws -> AttachmentHandle
    func focus(_ handle: AttachmentHandle)
    func isOpen(_ handle: AttachmentHandle) -> Bool
    func setTitleSeed(_ handle: AttachmentHandle, title: String?)
}
