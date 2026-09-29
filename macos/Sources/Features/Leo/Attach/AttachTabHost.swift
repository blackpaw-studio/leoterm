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
    case processExited(AttachmentHandle)
    /// The attachment (if any) that now has keyboard focus: the focused
    /// surface of the key window, while it is that window's first
    /// responder. `nil` when keyboard focus left every attachment (the
    /// sidebar, another surface). Drives the sidebar row link.
    case focusChanged(AttachmentHandle?)
    /// The attachment (if any) the user is looking at: the key window's
    /// focused split, whether or not it has keyboard focus -- clicking the
    /// sidebar doesn't stop the terminal beside it counting as viewed.
    /// `nil` while the app is inactive. Drives attention and Jump. A
    /// non-nil `.focusChanged` implies the same handle is viewed.
    case viewingChanged(AttachmentHandle?)
    /// The app went inactive or has no key window: nothing is focused, but
    /// focus didn't move anywhere either. The next `.focusChanged` says
    /// where it resumed.
    case focusSuspended
}

extension Notification.Name {
    /// Posted by `BaseTerminalController` whenever its `focusedSurface` is
    /// assigned (object: the controller).
    static let leoFocusedSurfaceDidChange = Notification.Name("studio.blackpaw.leo.focusedSurfaceDidChange")
    /// Posted by `Ghostty.SurfaceView` when it gains or loses keyboard focus
    /// (first responder in the key window; object: the surface).
    static let leoSurfaceFocusDidChange = Notification.Name("studio.blackpaw.leo.surfaceFocusDidChange")
    /// Posted by `Ghostty.App` when a surface's process exits while it is
    /// in no window -- hidden in a live pool (B-056) -- so Ghostty shows no
    /// exit message for it (object: the surface).
    static let leoWindowlessChildExited = Notification.Name("studio.blackpaw.leo.windowlessChildExited")
}

@MainActor protocol AttachTabHost: AnyObject {
    var lifecycleEvents: AsyncStream<AttachLifecycleEvent> { get }
    /// The attachment that has keyboard focus in the key window of the
    /// active app, if any. Changes are reported as `.focusChanged`.
    var focusedHandle: AttachmentHandle? { get }
    /// The attachment the user is looking at, if any (see
    /// `.viewingChanged`, which reports its changes).
    var viewedHandle: AttachmentHandle? { get }
    /// How many focus events (`.focusChanged`, `.viewingChanged`,
    /// `.focusSuspended`) have been yielded on
    /// `lifecycleEvents` so far. The Nth focus event on the stream is report
    /// N, so a consumer can tell a report yielded before some moment (e.g.
    /// a user's click) from one yielded after it, even if it hasn't been
    /// received yet.
    var focusReportCount: Int { get }
    /// `requestID` looks up the inherited `Ghostty.SurfaceConfiguration`
    /// (if any) from `LeoRequestConfigStore` -- see
    /// `GhosttyAttachTabHost.configuration(command:workingDirectory:requestID:)`.
    ///
    /// B-055: shows a new surface in `origin`'s content area in place of
    /// whatever it showed (the whole split tree), or fills it when it is
    /// the empty start screen. Never a tab: a window has one content area.
    func showInContent(command: String, workingDirectory: String?, origin: LeoWindowID, requestID: UUID) throws -> AttachmentHandle
    /// Whether `showInContent` may replace what `origin` shows. Agents
    /// detach losslessly (tmux keeps them), so only a plain shell with a
    /// running process asks first; `false` when the user cancels.
    func confirmReplacingContent(origin: LeoWindowID) async -> Bool
    func openWindow(command: String, workingDirectory: String?, requestID: UUID) throws -> AttachmentHandle
    /// Always creates a new split (tmux allows multiple clients on the same
    /// agent, so -- unlike `.content` -- this is never a reuse/focus path).
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
    /// Closes `origin`'s window when it is still an untouched start screen
    /// (`LeoStartScreenState.isUntouched`): its request went to an agent
    /// already on screen in another window instead (B-047, B-055).
    /// Anything else -- a terminal, an editor -- keeps it.
    func discardEmptyPlaceholder(origin: LeoWindowID)
    func focus(_ handle: AttachmentHandle)
    /// Attached: shown, or hidden in its window's live pool (B-056).
    func isOpen(_ handle: AttachmentHandle) -> Bool
    /// On screen: in its window's content area (not hidden in its pool).
    func isShown(_ handle: AttachmentHandle) -> Bool
    /// B-056: shows the hidden content holding `handle` in its window's
    /// content area again -- the same surfaces, no new tmux client -- in
    /// place of what it showed (which is pooled in turn). `false` when
    /// `handle` isn't hidden in its window's pool.
    func reveal(_ handle: AttachmentHandle) -> Bool
    /// B-056: lets go of the hidden content holding `handle`, so its tmux
    /// clients detach and its handles close. Content on screen is left
    /// alone.
    func release(_ handle: AttachmentHandle)
    /// Titles `handle`'s surface -- and so its window, while focused --
    /// after the agent attached in it (B-052), in place of whatever title
    /// the terminal sets.
    func setAgentName(_ handle: AttachmentHandle, name: String)
}
