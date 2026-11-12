import AppKit
import GhosttyKit

/// Tells libghostty whether a surface is on screen, so a hidden one stops
/// rendering (its renderer thread skips frame updates while occluded). The
/// surface view's `isWindowVisible` records what libghostty was last told, so
/// repeating a state is a no-op; a new surface starts visible, as
/// libghostty's renderer does.
enum LeoSurfaceDrawing {
    @MainActor static func set(_ view: Ghostty.SurfaceView, visible: Bool) {
        guard let surface = view.surface else { return }
        if visible {
            guard !view.isWindowVisible else { return }
            ghostty_surface_set_occlusion(surface, true)
            view.isWindowVisible = true
        } else {
            view.focusDidChange(false)
            if view.isWindowVisible { ghostty_surface_set_occlusion(surface, false) }
            view.isWindowVisible = false
        }
    }
}
