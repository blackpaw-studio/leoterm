import SwiftUI

/// Renders the window's terminal surfaces as an auto-arranging grid — Leo's
/// replacement for the binary split-tree view.
///
/// Phase 2c: dynamic auto-packing + click-to-focus + zoom + **hover-grow**
/// (Mode A elastic reflow). Hovering a cell grows it (neighbors squish); when
/// nothing is hovered, the focused cell stays grown. Modes B/C, fixed cells,
/// and debounced PTY resize come later.
struct TerminalGridView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    /// Dead-agent placeholders to render alongside live surfaces (empty for normal grids).
    var deadCells: [DeadCell] = []
    /// Respawn a dead cell's agent.
    var onRespawnDead: (DeadCell) -> Void = { _ in }
    /// Remove a dead cell from the board.
    var onRemoveDead: (DeadCell) -> Void = { _ in }
    /// Resolves the non-bell status inputs for a surface (agent identity +
    /// lifecycle). Default is a non-agent so plain grids show no agent status.
    var statusInputs: (Ghostty.SurfaceView.ID) -> CellStatusInputs = { _ in .none }
    /// Shared live-activity observer, threaded into `AgentCellOverlay` so the
    /// working/idle dot reacts to daemon updates without a full grid
    /// re-render. Defaults to a config-less (always `.unknown`) instance so
    /// previews and other callers that don't wire Leo activity still compile
    /// and render correctly.
    var activityStore: LeoActivityStore = TerminalGridView.defaultActivityStore
    private static let defaultActivityStore = LeoActivityStore(config: nil)

    /// Called when the empty-state "New Agent" button is tapped.
    var onAddAgent: (() -> Void)?
    /// Called when the empty-state "New Terminal" button is tapped.
    var onAddTerminal: (() -> Void)?

    /// Row-height pins loaded from the persisted board (row index → height).
    /// Applied once on first render and on subsequent external changes (e.g.
    /// board reload). Pins that survive a cell-count change are best-effort.
    var initialPinnedRowsByIndex: [Int: CGFloat] = [:]
    /// Called whenever the user changes pin state; receives the current row-indexed
    /// pins so the caller can persist them.
    var onPinsChanged: ([Int: CGFloat]) -> Void = { _ in }

    /// Gap between cells, in points (config key `grid-cell-gap`).
    var gap: CGFloat = 4
    /// How much an emphasized cell grows relative to its neighbors
    /// (config key `grid-hover-grow-factor`).
    var growthFactor: CGFloat = 1.6
    /// Whether hovering/focusing a cell grows it (config key `grid-hover-grow`).
    /// When false the grid stays packed with no emphasis.
    var hoverGrow: Bool = true

    /// The cell currently under the pointer, if any.
    @State private var hoveredID: Ghostty.SurfaceView.ID?
    /// Row heights pinned by the user via drag, keyed by any cell ID in that row.
    @State private var pinnedRowHeights: [Ghostty.SurfaceView.ID: CGFloat] = [:]
    /// The focused surface (emphasis target when nothing is hovered).
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    /// Whether the pointer is hovering the cell whose pin handle is shown, keyed
    /// by cell id. Drives the hairline reveal-on-hover for the drag strip.
    @State private var hoveredPinHandleID: Ghostty.SurfaceView.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Minimum pinned row height, in points. Mirrors the drag lower bound so a
    /// pinned row never collapses to something unusable.
    private static let minPinnedRowHeight: CGFloat = 40
    /// Pinned row heights are capped at this fraction of the container height
    /// so a single pinned row can never crowd out every other row.
    private static let maxPinnedRowHeightFraction: CGFloat = 0.8

    private struct PlacedCell: Identifiable {
        let id: UUID
        let item: GridCellItem
        let frame: CGRect
    }

    /// All renderable items: live surfaces followed by dead placeholders.
    private var allItems: [GridCellItem] {
        Array(tree).map(GridCellItem.surface) + deadCells.map(GridCellItem.dead)
    }

    var body: some View {
        Group {
            if let zoomed = tree.zoomed, case .leaf(let surface) = zoomed {
                Ghostty.InspectableSurface(surfaceView: surface, isSplit: false)
            } else {
                grid
            }
        }
        // Restore pinned row heights from an external source (e.g. board reload).
        // Guard prevents a feedback loop: if the current row-indexed pins already
        // match the incoming value, skip the update so we don't rewrite the
        // UUID-keyed state unnecessarily.
        //
        // onAppear handles the initial render case (pins silently fail to restore
        // if the view is created after the board already loaded); onChange handles
        // subsequent external changes. Together they replicate `onChange(initial:)`
        // behaviour while staying compatible with the macOS 13 deployment target.
        .onAppear {
            let current = uuidToRowIndexed(pinnedRowHeights)
            if current != initialPinnedRowsByIndex {
                pinnedRowHeights = rowIndexedToUUID(initialPinnedRowsByIndex)
            }
        }
        .onChange(of: initialPinnedRowsByIndex) { newValue in
            let current = uuidToRowIndexed(pinnedRowHeights)
            if current != newValue {
                pinnedRowHeights = rowIndexedToUUID(newValue)
            }
        }
        // Report pin changes to the caller for persistence. This fires for both
        // user-initiated drags and the initial restore assignment above; the
        // caller's debounce absorbs the extra event from restore.
        .onChange(of: pinnedRowHeights) { newPins in
            onPinsChanged(uuidToRowIndexed(newPins))
        }
    }

    @ViewBuilder
    private var grid: some View {
        let items = allItems
        if items.isEmpty {
            emptyBoardView
        } else {
            let isSplit = items.count > 1
            let emphasized = hoverGrow ? (hoveredID ?? focusedSurface?.id) : nil
            GeometryReader { geo in
                let placed = GridLayout(cells: items)
                    .frames(in: geo.size, gap: gap, pinnedRowHeights: pinnedRowHeights,
                            emphasizing: emphasized, factor: growthFactor,
                            minimumPinnedRowHeight: Self.minPinnedRowHeight)
                    .map { PlacedCell(id: $0.cell.id, item: $0.cell, frame: $0.frame) }
                ZStack(alignment: .topLeading) {
                    ForEach(placed) { placedCell in
                        cellView(for: placedCell, isSplit: isSplit, isFocused: placedCell.id == focusedSurface?.id)
                            .clipShape(RoundedRectangle(cornerRadius: LeoPalette.cellCornerRadius))
                            .overlay {
                                RoundedRectangle(cornerRadius: LeoPalette.cellCornerRadius)
                                    .stroke(
                                        placedCell.id == focusedSurface?.id
                                            ? LeoPalette.focusedCellStroke : LeoPalette.cellStroke,
                                        lineWidth: placedCell.id == focusedSurface?.id ? 1.5 : 1)
                                    .allowsHitTesting(false)
                            }
                            .frame(width: placedCell.frame.width, height: placedCell.frame.height)
                            .overlay(alignment: .bottom) {
                                pinHandle(for: placedCell, containerHeight: geo.size.height)
                            }
                            .position(x: placedCell.frame.midX, y: placedCell.frame.midY)
                            .onHover { hovering in
                                if hovering {
                                    hoveredID = placedCell.id
                                } else if hoveredID == placedCell.id {
                                    hoveredID = nil
                                }
                            }
                    }
                }
                .animation(reflowAnimation, value: hoveredID)
                .animation(reflowAnimation, value: focusedSurface?.id)
                .animation(reflowAnimation, value: pinnedRowHeights)
                .animation(reflowAnimation, value: placed.map(\.id))
            }
        }
    }

    /// The spring used to reflow the grid on hover/focus/pin changes and on
    /// cell add/remove/swap. `nil` under Reduce Motion so cells snap into
    /// place instead of animating.
    private var reflowAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.86)
    }

    /// Empty-board placeholder shown when the board has no cells at all.
    private var emptyBoardView: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No cells on this board")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("New Agent") { onAddAgent?() }
                    .buttonStyle(.bordered)
                    .disabled(onAddAgent == nil)
                Button("New Terminal") { onAddTerminal?() }
                    .buttonStyle(.bordered)
                    .disabled(onAddTerminal == nil)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Renders a placed cell: a live terminal surface (focusable) or a dead placeholder.
    @ViewBuilder
    private func cellView(for placed: PlacedCell, isSplit: Bool, isFocused: Bool) -> some View {
        switch placed.item {
        case .surface(let surface):
            Ghostty.InspectableSurface(surfaceView: surface, isSplit: isSplit)
                .onTapGesture { Ghostty.moveFocus(to: surface) }
                .overlay {
                    AgentCellOverlay(
                        surface: surface, inputs: statusInputs(surface.id),
                        activityStore: activityStore,
                        isFocused: isFocused, isHovered: hoveredID == placed.id)
                }
        case .dead(let dead):
            DeadCellView(
                snapshot: dead.snapshot,
                onRespawn: { onRespawnDead(dead) },
                onRemove: { onRemoveDead(dead) })
                // A stopped agent is an error state in the status language — a
                // small red dot keeps dead cells consistent with live-cell status.
                .overlay { CellStatusOverlay(status: .error) }
        }
    }

    /// A thin grab strip along a cell's bottom edge: drag to pin the row height,
    /// double-click to unpin. `containerHeight` bounds how tall a pin can grow.
    private func pinHandle(for item: PlacedCell, containerHeight: CGFloat) -> some View {
        let isPinned = pinnedRowHeights[item.id] != nil
        let isHovered = hoveredPinHandleID == item.id
        return Rectangle()
            .fill(LeoPalette.cellStroke)
            .opacity(isPinned ? 1 : (isHovered ? 0.6 : 0.001))
            .frame(height: isPinned ? 3 : 2)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                hoveredPinHandleID = hovering ? item.id : (hoveredPinHandleID == item.id ? nil : hoveredPinHandleID)
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let maxHeight = containerHeight * Self.maxPinnedRowHeightFraction
                        let proposed = item.frame.height + value.translation.height
                        let newHeight = min(maxHeight, max(Self.minPinnedRowHeight, proposed))
                        pinnedRowHeights[item.id] = newHeight
                    }
            )
            .onTapGesture(count: 2) { pinnedRowHeights[item.id] = nil }
            .help(pinnedRowHeights[item.id] != nil
                  ? "Pinned row — drag to resize, double-click to unpin"
                  : "Drag to pin this row's height")
    }

    // MARK: - Pin conversion helpers

    /// Convert UUID-keyed (view-internal) pins to row-indexed (persisted) form.
    private func uuidToRowIndexed(_ pins: [UUID: CGFloat]) -> [Int: CGFloat] {
        let items = allItems
        let (_, columns) = GridLayout<GridCellItem>.dimensions(forCount: items.count)
        var result: [Int: CGFloat] = [:]
        for (index, item) in items.enumerated() {
            if let height = pins[item.id] {
                let row = columns > 0 ? index / columns : 0
                result[row] = max(result[row] ?? 0, height)
            }
        }
        return result
    }

    /// Convert row-indexed (persisted) pins to UUID-keyed (view-internal) form.
    /// Uses the first cell in each row as the representative key — the grid
    /// renders identically regardless of which cell in the row carries the pin.
    private func rowIndexedToUUID(_ pins: [Int: CGFloat]) -> [UUID: CGFloat] {
        let items = allItems
        let (_, columns) = GridLayout<GridCellItem>.dimensions(forCount: items.count)
        var seenRows = Set<Int>()
        var result: [UUID: CGFloat] = [:]
        for (index, item) in items.enumerated() {
            let row = columns > 0 ? index / columns : 0
            if let height = pins[row], !seenRows.contains(row) {
                seenRows.insert(row)
                result[item.id] = height
            }
        }
        return result
    }
}

/// Small top-trailing identity chrome for `.agent` grid cells — otherwise a
/// wall of identical terminal surfaces is impossible to tell apart. Fades
/// toward transparent while the pointer is over the cell so it never
/// occludes terminal text; `.pty` cells render no capsule at all.
/// Observes a live surface's `bell` flag, resolves `CellStatus` once per body
/// evaluation, and feeds that single result to both the status dot/glow and
/// the identity capsule's status word — avoids deriving status twice (and
/// the two derivations drifting out of sync).
private struct AgentCellOverlay: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    let inputs: CellStatusInputs
    /// Observed (not just read) so a daemon-driven activity change re-renders
    /// this overlay on its own — no full grid re-render needed.
    @ObservedObject var activityStore: LeoActivityStore
    let isFocused: Bool
    let isHovered: Bool

    var body: some View {
        let activity = inputs.name.map { activityStore.activity(for: $0) } ?? .unknown
        let status = deriveCellStatus(
            isAgent: inputs.isAgent, hasBell: surface.bell, lifecycle: inputs.lifecycle, activity: activity)
        ZStack(alignment: .topTrailing) {
            CellStatusOverlay(status: status)
            if inputs.isAgent, let name = inputs.name {
                CellIdentityCapsule(
                    name: name,
                    statusWord: isFocused ? status.statusWord : nil,
                    isHovered: isHovered)
            }
        }
    }
}

private struct CellIdentityCapsule: View {
    let name: String
    /// Appended after the name on the focused cell (e.g. "needs you").
    let statusWord: String?
    let isHovered: Bool

    private var label: String {
        guard let statusWord else { return name }
        return "\(name) — \(statusWord)"
    }

    var body: some View {
        Text(label)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .opacity(isHovered ? 0.35 : 0.85)
            .padding(6)
            .allowsHitTesting(false)
            .accessibilityLabel("Agent \(name)")
    }
}
