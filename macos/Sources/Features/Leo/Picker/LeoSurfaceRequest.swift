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
    case placeholder
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

    init(id: UUID = UUID(), origin: LeoWindowID, disposition: LeoSurfaceDisposition, splitSourceSurface: UUID? = nil) {
        self.id = id
        self.origin = origin
        self.disposition = disposition
        self.splitSourceSurface = splitSourceSurface
    }
}
