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
/// `TerminalController.newSplit`, `AppDelegate.leoRouteNewWindow`/
/// `ghosttyNewTab`) and consumed by `GhosttyAttachContentHost` when it builds
/// the destination's configuration. `LeoNewSurfaceRouter`'s
/// `onRequestEnded` hook drops an entry once its request retires or is
/// displaced before ever being chosen, so this never grows unbounded.
///
/// B-145: it also holds, per window, what a bare start screen inherited
/// (⌘N's font size) with no request to carry it. `GhosttyAttachContentHost`
/// falls back to it for the surface that fills that start screen -- the one
/// place every path (palette, sidebar agent, dispatch, New Terminal, plain
/// shell) goes from empty start screen to content -- and releases it there,
/// so only the window's first surface inherits it. A failed or cancelled
/// fill leaves it held; the window closing releases it.
@MainActor final class LeoRequestConfigStore {
    private var configs: [UUID: Ghostty.SurfaceConfiguration] = [:]
    private var startScreenConfigs: [LeoWindowID: Ghostty.SurfaceConfiguration] = [:]

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

    /// Holds `config` for the surface that fills `window`'s start screen.
    /// A `nil` config holds nothing.
    func hold(_ config: Ghostty.SurfaceConfiguration?, forStartScreen window: LeoWindowID) {
        startScreenConfigs[window] = config
    }

    /// What `window`'s start screen holds, left held until
    /// `releaseStartScreen(_:)`.
    func heldConfig(forStartScreen window: LeoWindowID) -> Ghostty.SurfaceConfiguration? {
        startScreenConfigs[window]
    }

    /// `window`'s start screen was filled, or the window closed.
    func releaseStartScreen(_ window: LeoWindowID) {
        startScreenConfigs.removeValue(forKey: window)
    }
}
