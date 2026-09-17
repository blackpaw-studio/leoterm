import Foundation
import GhosttyKit

/// Side table from `LeoSurfaceRequest.id` to the `Ghostty.SurfaceConfiguration`
/// inherited from whatever triggered the request (a surface's working
/// directory, font overrides, etc). Kept out of `LeoSurfaceRequest` itself
/// -- a pure value type with no AppKit/Ghostty dependency -- since the
/// config only matters at the point the destination surface is actually
/// created, not to routing identity.
///
/// Entries are set by `LeoRuntime.routeNewSurface` (the intercept points:
/// `TerminalController.newSplit`, `AppDelegate.ghosttyNewWindow`/
/// `ghosttyNewTab`) and consumed by `GhosttyAttachTabHost` when it builds
/// the destination's configuration. `LeoNewSurfaceRouter`'s
/// `onRequestEnded` hook drops an entry once its request retires or is
/// displaced before ever being chosen, so this never grows unbounded.
@MainActor final class LeoRequestConfigStore {
    private var configs: [UUID: Ghostty.SurfaceConfiguration] = [:]

    /// Records `config` for `requestID`. A `nil` config is a no-op (most
    /// gestures have nothing to inherit) rather than storing `nil` -- keeps
    /// `consume`'s "was anything stored" and "was it nil" indistinguishable,
    /// which is fine since callers only ever want "do I have something to
    /// start from, or should I use a fresh default".
    func set(_ config: Ghostty.SurfaceConfiguration?, for requestID: UUID) {
        guard let config else { return }
        configs[requestID] = config
    }

    /// Removes and returns the stored config for `requestID`, if any.
    /// One-shot by design: a request is only ever "created from" once.
    func consume(for requestID: UUID) -> Ghostty.SurfaceConfiguration? {
        configs.removeValue(forKey: requestID)
    }

    /// Drops the entry for `requestID` without consuming it (e.g. the
    /// request was cancelled or superseded before ever being chosen).
    func drop(for requestID: UUID) {
        configs.removeValue(forKey: requestID)
    }
}
