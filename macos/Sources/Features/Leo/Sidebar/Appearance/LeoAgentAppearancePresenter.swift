import AppKit
import SwiftUI

/// Shows an agent's Appearance editor (`LeoAgentAppearancePopover`) in an
/// `NSPopover`, for callers outside the sidebar's SwiftUI row (the toolbar's
/// title menu, Agents ▸ Appearance…). The row shows the same content in its
/// own SwiftUI popover.
@MainActor
enum LeoAgentAppearancePresenter {
    /// Anchors the editor below `anchor`; "Edit Rules…" closes it and opens Leo Settings.
    @discardableResult
    static func present(row: LeoAgentRow, runtime: LeoRuntime, relativeTo anchor: NSView) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: LeoAgentAppearancePopover(row: row, client: runtime.actions.appearanceClient(for: row.host)) { [weak popover, weak runtime] in
                popover?.close()
                runtime?.presentAppearanceRules(for: row.host)
            })
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        return popover
    }
}
