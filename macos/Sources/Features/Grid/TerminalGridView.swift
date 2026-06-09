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
    /// Row heights pinned by the user via drag, keyed by any cell ID in that row.
    @State private var pinnedRowHeights: [Ghostty.SurfaceView.ID: CGFloat] = [:]
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
                .frames(in: geo.size, gap: gap, pinnedRowHeights: pinnedRowHeights,
                        emphasizing: emphasized, factor: growthFactor)
                .map { PlacedCell(id: $0.cell.id, surface: $0.cell, frame: $0.frame) }
            ZStack(alignment: .topLeading) {
                ForEach(placed) { item in
                    Ghostty.InspectableSurface(surfaceView: item.surface, isSplit: isSplit)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .overlay(alignment: .bottom) { pinHandle(for: item) }
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
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pinnedRowHeights)
        }
    }

    /// A thin grab strip along a cell's bottom edge: drag to pin the row height,
    /// double-click to unpin.
    private func pinHandle(for item: PlacedCell) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(pinnedRowHeights[item.id] != nil ? 0.5 : 0.001))
            .frame(height: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let newHeight = max(40, item.frame.height + value.translation.height)
                        pinnedRowHeights[item.id] = newHeight
                    }
            )
            .onTapGesture(count: 2) { pinnedRowHeights[item.id] = nil }
            .help(pinnedRowHeights[item.id] != nil
                  ? "Pinned row — drag to resize, double-click to unpin"
                  : "Drag to pin this row's height")
    }
}
