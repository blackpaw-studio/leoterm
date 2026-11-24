import AppKit

/// Where a dragged pane can dock (B-440): pure geometry, so the overlay and
/// its tests agree. Coordinates are a non-flipped view's: below is the low-y half.
enum LeoDockDropZone {
    /// The share of the terminal a zone covers along its edge: the half a
    /// dock takes when it opens with no remembered size.
    static let zoneFraction: CGFloat = 0.5

    /// The one edge `pane` can be dropped on: the one it isn't on, so a
    /// drop never does nothing.
    static func target(for pane: LeoDockPane, layout: LeoPaneDockLayout) -> LeoDockEdge {
        layout.edge(of: pane).opposite
    }

    /// The part of `bounds` along `edge` a drop on it lands in.
    static func frame(for edge: LeoDockEdge, in bounds: NSRect) -> NSRect {
        switch edge {
        case .right:
            NSRect(x: bounds.maxX - bounds.width * zoneFraction, y: bounds.minY, width: bounds.width * zoneFraction, height: bounds.height)
        case .below:
            NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height * zoneFraction)
        }
    }

    static func contains(_ point: NSPoint, edge: LeoDockEdge, in bounds: NSRect) -> Bool {
        frame(for: edge, in: bounds).contains(point)
    }

    /// What the zone is labelled.
    static func title(for edge: LeoDockEdge) -> String {
        edge == .right ? "Dock Right" : "Dock Below"
    }
}
