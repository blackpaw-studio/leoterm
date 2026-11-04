import AppKit
import Combine
import SwiftUI

/// Where the sidebar split sits against the agent window's toolbar.
///
/// An agent window (`LeoAgentTerminalWindow`) has a unified toolbar over a
/// full-size content view, and its split ignores the top safe area so the
/// glass sidebar runs under the toolbar and the traffic lights. The
/// sidebar's header and the side panes' headers then take the toolbar's
/// real height (`LeoToolbarInset`, from `contentLayoutRect`) plus
/// `LeoSidebarChromeMetrics.topInset`, never a constant: the toolbar grows
/// with its subtitle, and full screen releases it at rest. The detail
/// column stays inside the safe area, so the terminal starts under the
/// toolbar rather than behind it.
enum LeoTitlebarInsets {
    /// The top safe-area edges the sidebar split and its sidebar ignore in
    /// `window`.
    static func splitIgnoredEdges(in window: NSWindow?) -> Edge.Set {
        window is LeoAgentTerminalWindow ? .top : []
    }

    /// Centres `control`, one of a side pane's header controls, on a sidebar
    /// header row (`LeoSidebarChromeMetrics.headerRowHeight`) starting
    /// `inset.headerTop` below the pane's top edge, and keeps it there as
    /// the toolbar's height changes (until the returned subscription is
    /// dropped). The header's own controls are centred on one line, so the
    /// whole header follows; an empty first row takes up the room above it.
    /// The control takes the row's (even) height: an odd-height frame
    /// centred on a whole-point line snaps half a point off where layout
    /// rounds to whole points (B-153).
    @MainActor
    static func insetHeader(of pane: NSStackView, inset: LeoToolbarInset, centring control: NSView) -> AnyCancellable {
        let spacer = NSView()
        spacer.setAccessibilityElement(false)
        pane.insertArrangedSubview(spacer, at: 0)
        let centre = control.centerYAnchor.constraint(equalTo: pane.topAnchor)
        NSLayoutConstraint.activate([
            spacer.widthAnchor.constraint(equalTo: pane.widthAnchor),
            control.heightAnchor.constraint(equalToConstant: LeoSidebarChromeMetrics.headerRowHeight),
            centre,
        ])
        return inset.$height.sink { [weak centre] height in
            centre?.constant = LeoToolbarInset.headerTop(forHeight: height) + LeoSidebarChromeMetrics.headerRowHeight / 2
        }
    }
}
