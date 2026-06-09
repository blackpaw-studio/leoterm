import SwiftUI

/// Renders the window's terminal surfaces as an auto-arranging grid — Leo's
/// replacement for the binary `TerminalSplitTreeView`. Mirrors that view's
/// interface (`tree`, `action`) so it drops in at the same call site.
///
/// Phase 2b: dynamic auto-packing (via `GridLayout`), click-to-focus (sticky),
/// and zoom passthrough. Hover-grow, fixed/pinned cells, and drag-resize come later.
struct TerminalGridView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    /// Gap between cells, in points. Made configurable in Phase 2e.
    private let gap: CGFloat = 4

    var body: some View {
        if let zoomed = tree.zoomed, case .leaf(let surface) = zoomed {
            Ghostty.InspectableSurface(surfaceView: surface, isSplit: false)
        } else {
            grid
        }
    }

    private var grid: some View {
        let surfaces = Array(tree)
        let isSplit = surfaces.count > 1
        return GeometryReader { geo in
            let placed = GridLayout(cells: surfaces).frames(in: geo.size, gap: gap)
            let cells = placed.map { item in
                PlacedCell(id: item.cell.id, surface: item.cell, frame: item.frame)
            }
            ZStack(alignment: .topLeading) {
                ForEach(cells) { item in
                    Ghostty.InspectableSurface(surfaceView: item.surface, isSplit: isSplit)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .position(x: item.frame.midX, y: item.frame.midY)
                        .onTapGesture { Ghostty.moveFocus(to: item.surface) }
                }
            }
        }
    }
}

// MARK: - Private helpers

private struct PlacedCell: Identifiable {
    let id: UUID
    let surface: Ghostty.SurfaceView
    let frame: CGRect
}
