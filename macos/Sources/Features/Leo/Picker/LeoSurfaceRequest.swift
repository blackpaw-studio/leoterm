import Foundation

/// Direction for a `split` disposition. Deliberately independent of
/// `SplitTree`'s own direction type -- this is the Leo-facing request
/// vocabulary, not the surface tree's internal representation.
enum LeoSplitDirection: Equatable, Sendable {
    case left, right, up, down
}

/// Where a resolved picker choice should land.
enum LeoSurfaceDisposition: Equatable, Sendable {
    /// The origin window's one content area, in place of what it shows
    /// (B-055); the empty start screen is filled.
    case content
    case split(LeoSplitDirection)
    case window
    case placeholder(surfaceID: UUID?)

    static var placeholder: Self { .placeholder(surfaceID: nil) }
}

extension LeoSurfaceDisposition {
    /// B-047, B-055: one agent is on screen in at most one window, so an
    /// agent already shown goes forward instead: in the content area (Choose
    /// Agent…, a row), on the start screen, and in a new window (⌘-click, ⌘↩). A
    /// split and a pane left by an exited attach always attach.
    var focusesAgentOnScreen: Bool {
        switch self {
        case .content, .window, .placeholder(surfaceID: nil): true
        case .split, .placeholder: false
        }
    }

    /// Where Return shows the choice in this window, so ⌘Return (a new
    /// window, D-104) is a real alternative: Choose Agent… (⌘O) and the
    /// start screen.
    var offersNewWindow: Bool { self == .content || self == .placeholder }
}

/// B-055 (D-104): where an agent choice goes -- where the request asked
/// (Return, a click), or a new window (⌘↩ in the palette). Either way an
/// agent already on screen is focused instead.
enum LeoAttachPlacement: Equatable, Sendable {
    case requested
    case newWindow
}

struct LeoSurfaceRequestTarget: Hashable, Sendable {
    let windowID: LeoWindowID
    let surfaceID: UUID?
}

/// One in-flight "new surface" gesture (Choose Agent…, Cmd+D, Cmd+N,
/// launch window).
/// Pure value type; `LeoNewSurfaceRouter` tracks these by `id` to detect
/// staleness and `origin` to detect which window a follow-up request
/// supersedes.
struct LeoSurfaceRequest: Equatable, Sendable {
    let id: UUID
    let origin: LeoWindowID
    let disposition: LeoSurfaceDisposition
    /// The surface a `split` originates from. Nil for non-split dispositions.
    let splitSourceSurface: UUID?

    /// The immutable destination identity. Leaf placeholders are keyed by
    /// their retained surface; the original empty-window placeholder is nil.
    var routingTarget: LeoSurfaceRequestTarget {
        let surfaceID: UUID? = if case .placeholder(let surfaceID) = disposition { surfaceID } else { nil }
        return .init(windowID: origin, surfaceID: surfaceID)
    }

    init(id: UUID = UUID(), origin: LeoWindowID, disposition: LeoSurfaceDisposition, splitSourceSurface: UUID? = nil) {
        self.id = id
        self.origin = origin
        self.disposition = disposition
        self.splitSourceSurface = splitSourceSurface
    }

    /// This request (same id, so its inherited configuration still
    /// applies) sent to a new window instead (⌘↩, ⌘-click).
    var inNewWindow: LeoSurfaceRequest {
        LeoSurfaceRequest(id: id, origin: origin, disposition: .window)
    }
}
