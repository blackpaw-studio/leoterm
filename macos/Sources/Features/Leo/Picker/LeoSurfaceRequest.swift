import Foundation

/// Direction for a `split` disposition. Deliberately independent of
/// `SplitTree`'s own direction type -- this is the Leo-facing request
/// vocabulary, not the surface tree's internal representation.
enum LeoSplitDirection: Equatable, Sendable {
    case left, right, up, down
}

/// Where a resolved picker choice should land.
enum LeoSurfaceDisposition: Equatable, Sendable {
    case tab
    case split(LeoSplitDirection)
    case window
    case placeholder(surfaceID: UUID?)

    static var placeholder: Self { .placeholder(surfaceID: nil) }
}

extension LeoSurfaceDisposition {
    /// B-047: where an agent's open tab stands in for a new one. A fresh
    /// tab (⌘T) or start screen (`.placeholder(surfaceID: nil)`) does; a
    /// split, a new window, and a pane left in an existing tab by an exited
    /// attach always attach.
    var reusesOpenTab: Bool {
        switch self {
        case .tab, .placeholder(surfaceID: nil): true
        case .split, .window, .placeholder: false
        }
    }
}

/// B-047: whether an attach goes to the agent's open tab (the default) or
/// always opens a new one (⌘-click, ⌘Return).
enum LeoAttachReuse: Equatable, Sendable {
    case focusExisting
    case alwaysNew
}

struct LeoSurfaceRequestTarget: Hashable, Sendable {
    let windowID: LeoWindowID
    let surfaceID: UUID?
}

/// One in-flight "new surface" gesture (Cmd+T, Cmd+D, Cmd+N, launch window).
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
}
