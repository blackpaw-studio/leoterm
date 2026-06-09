import SwiftUI

/// Renders the window's terminal surfaces as an auto-arranging grid — Leo's
/// replacement for the binary `TerminalSplitTreeView`.
///
/// Phase 2c: dynamic auto-packing + click-to-focus + zoom + **hover-grow**
/// (Mode A elastic reflow). Hovering a cell grows it (neighbors squish); when
/// nothing is hovered, the focused cell stays grown. Modes B/C, fixed cells,
/// and debounced PTY resize come later.
struct TerminalGridView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    /// Gap between cells, in points. Made configurable in Phase 2e.
    private let gap: CGFloat = 4
    /// How much an emphasized cell grows relative to its neighbors.
    private let growthFactor: CGFloat = 1.6

    /// The cell currently under the pointer, if any.
    @State private var hoveredID: Ghostty.SurfaceView.ID?
    /// The focused surface (emphasis target when nothing is hovered).
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface

    private struct PlacedCell: Identifiable {
        let id: Ghostty.SurfaceView.ID
        let surface: Ghostty.SurfaceView
        let frame: CGRect
    }

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
        let emphasized = hoveredID ?? focusedSurface?.id
        return GeometryReader { geo in
            let placed = GridLayout(cells: surfaces)
                .frames(in: geo.size, gap: gap, emphasizing: emphasized, factor: growthFactor)
                .map { PlacedCell(id: $0.cell.id, surface: $0.cell, frame: $0.frame) }
            ZStack(alignment: .topLeading) {
                ForEach(placed) { item in
                    Ghostty.InspectableSurface(surfaceView: item.surface, isSplit: isSplit)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .position(x: item.frame.midX, y: item.frame.midY)
                        .onTapGesture { Ghostty.moveFocus(to: item.surface) }
                        .onHover { hovering in
                            if hovering {
                                hoveredID = item.id
                            } else if hoveredID == item.id {
                                hoveredID = nil
                            }
                        }
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: hoveredID)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: focusedSurface?.id)
        }
    }
}
