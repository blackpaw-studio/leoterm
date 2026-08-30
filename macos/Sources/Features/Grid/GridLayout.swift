import Foundation

/// Floor kept for flex (unpinned) row/column slots when there is room to
/// spare it — keeps a lone flex slot from being squeezed toward zero by
/// aggressive pinning, without being a hard guarantee when space genuinely
/// runs out. File-scope because static stored properties aren't supported in
/// extensions of a generic type.
private let gridLayoutMinFlexExtent: CGFloat = 24

/// An immutable model of an auto-arranging grid of cells.
///
/// Phase 2a models **dynamic** cells only: cells are auto-packed into a
/// square-ish, width-biased grid. Fixed/pinned cells arrive in a later phase.
///
/// Generic over an `Identifiable` view type so it can be unit-tested with a
/// mock and used with `Ghostty.SurfaceView` in the app. Mutation methods follow
/// the codebase convention of returning a new copy (see `SplitTree`).
struct GridLayout<ViewType: Identifiable> {
    /// Cells in display order: row-major, left→right, top→bottom.
    private(set) var cells: [ViewType]

    init(cells: [ViewType] = []) {
        self.cells = cells
    }
}

extension GridLayout {
    var count: Int { cells.count }
    var isEmpty: Bool { cells.isEmpty }

    func contains(id: ViewType.ID) -> Bool {
        cells.contains { $0.id == id }
    }

    /// Returns a new layout with `cell` appended at the end (display order).
    func appending(_ cell: ViewType) -> Self {
        GridLayout(cells: cells + [cell])
    }

    /// Returns a new layout with the cell matching `id` removed (if present).
    func removing(id: ViewType.ID) -> Self {
        GridLayout(cells: cells.filter { $0.id != id })
    }
}

extension GridLayout {
    /// (rows, columns) for `n` cells: square-ish, biased wider (columns ≥ rows).
    /// rows = floor(sqrt(n)) (min 1); columns = ceil(n / rows). Zero for n ≤ 0.
    static func dimensions(forCount n: Int) -> (rows: Int, columns: Int) {
        guard n > 0 else { return (0, 0) }
        let rows = max(1, Int(Double(n).squareRoot().rounded(.down)))
        let columns = Int((Double(n) / Double(rows)).rounded(.up))
        return (rows, columns)
    }

    /// (rows, columns) for the current cell count.
    var dimensions: (rows: Int, columns: Int) { Self.dimensions(forCount: count) }
}

import CoreGraphics

extension GridLayout {
    /// Equal auto-packed layout (no emphasis). See `frames(in:gap:emphasizing:factor:)`.
    func frames(in size: CGSize, gap: CGFloat = 0) -> [(cell: ViewType, frame: CGRect)] {
        frames(in: size, gap: gap, emphasizing: nil, factor: 1)
    }

    /// Frames with one cell emphasized (grown). The emphasized cell's row gets
    /// extra height and its in-row column gets extra width (weight `factor`),
    /// everything else shrinking to fit — total extent preserved (elastic
    /// reflow, no overflow). `emphasizing: nil` / unknown id / `factor <= 1`
    /// yields the plain equal layout. Origin top-left.
    func frames(
        in size: CGSize,
        gap: CGFloat = 0,
        emphasizing emphasizedID: ViewType.ID?,
        factor: CGFloat
    ) -> [(cell: ViewType, frame: CGRect)] {
        frames(in: size, gap: gap, pinnedRowHeights: [:], emphasizing: emphasizedID, factor: factor)
    }

    /// Frames with optional per-row pinning. A row containing a cell present in
    /// `pinnedRowHeights` is fixed to that height (max if several); remaining
    /// height is shared by unpinned rows (emphasized unpinned row weight `factor`).
    /// Empty pins → identical to the emphasis-only layout.
    ///
    /// - Parameter minimumPinnedRowHeight: floor a pinned row is never scaled
    ///   below, even under flex-minimum pressure (see `distributeWithFixed`).
    func frames(
        in size: CGSize,
        gap: CGFloat = 0,
        pinnedRowHeights: [ViewType.ID: CGFloat],
        emphasizing emphasizedID: ViewType.ID?,
        factor: CGFloat,
        minimumPinnedRowHeight: CGFloat = 0
    ) -> [(cell: ViewType, frame: CGRect)] {
        let n = cells.count
        guard n > 0, size.width > 0, size.height > 0 else { return [] }
        let (rows, columns) = Self.dimensions(forCount: n)

        let emphasizedIndex = emphasizedID.flatMap { id in cells.firstIndex { $0.id == id } }
        let emphasizedRow = emphasizedIndex.map { $0 / columns }
        let g = max(1, factor)

        var pinnedHeightForRow = [Int: CGFloat]()
        for (index, cell) in cells.enumerated() {
            if let h = pinnedRowHeights[cell.id] {
                let row = index / columns
                pinnedHeightForRow[row] = max(pinnedHeightForRow[row] ?? 0, h)
            }
        }

        let rowHeights = Self.distributeWithFixed(
            total: size.height, gap: gap, count: rows,
            fixed: pinnedHeightForRow, minimumFixed: minimumPinnedRowHeight,
            flexWeight: { r in (r == emphasizedRow && pinnedHeightForRow[r] == nil) ? g : 1 })
        let rowOffsets = Self.offsets(of: rowHeights, gap: gap)

        var result: [(cell: ViewType, frame: CGRect)] = []
        result.reserveCapacity(n)
        for index in 0..<n {
            let row = index / columns
            let col = index % columns
            let isLastRow = row == rows - 1
            let cellsInRow = isLastRow ? (n - row * columns) : columns
            let emphasizedCol = (row == emphasizedRow) ? emphasizedIndex.map { $0 % columns } : nil
            let colWeights = (0..<cellsInRow).map { c in (c == emphasizedCol) ? g : 1 }
            let colWidths = Self.distribute(total: size.width, gap: gap, weights: colWeights)
            let colOffsets = Self.offsets(of: colWidths, gap: gap)
            result.append((cells[index], CGRect(
                x: colOffsets[col],
                y: rowOffsets[row],
                width: colWidths[col],
                height: rowHeights[row])))
        }
        return result
    }

    /// Distribute `total` across `count` slots: slots in `fixed` take their fixed
    /// size; the rest share the remainder (minus gaps) by `flexWeight`.
    ///
    /// If the fixed slots alone (plus gaps) would exceed `total`, every fixed
    /// slot is scaled down proportionally so the sum fits exactly — pinned
    /// rows/columns never overflow the container. Short of outright overflow,
    /// fixed slots are still shrunk just enough to leave flex slots at least
    /// `gridLayoutMinFlexExtent` in aggregate, but never below `minimumFixed`
    /// each — a fixed slot's own floor always wins over the flex minimum.
    /// Flex slots may drop below their minimum (even to 0) when honoring both
    /// floors isn't possible; if `minimumFixed` itself doesn't fit, every
    /// fixed slot scales down proportionally as a last resort so the total
    /// still never overflows `total`.
    private static func distributeWithFixed(
        total: CGFloat, gap: CGFloat, count: Int,
        fixed: [Int: CGFloat], minimumFixed: CGFloat = 0, flexWeight: (Int) -> CGFloat
    ) -> [CGFloat] {
        guard count > 0 else { return [] }
        let gaps = gap * CGFloat(count - 1)
        let available = max(0, total - gaps)
        let fixedTotal = fixed.values.reduce(0, +)
        let flexIndices = (0..<count).filter { fixed[$0] == nil }
        let requiredFlexMinimum = flexIndices.isEmpty ? 0 : CGFloat(flexIndices.count) * gridLayoutMinFlexExtent
        let requiredFixedFloor = CGFloat(fixed.count) * minimumFixed

        // Budget the fixed slots may consume: leave room for the flex minimum
        // when possible, but never below each fixed slot's own floor, and
        // never more than `available` (last-resort clamp when even the fixed
        // floor doesn't fit).
        let idealBudget = max(0, min(fixedTotal, available - requiredFlexMinimum))
        let flooredBudget = max(idealBudget, requiredFixedFloor)
        let fixedBudget = min(flooredBudget, available)
        let scale = fixedTotal > 0 ? fixedBudget / fixedTotal : 1

        let scaledFixedTotal = min(fixedTotal * scale, available)
        let remaining = max(0, available - scaledFixedTotal)
        let weightSum = flexIndices.reduce(0) { $0 + flexWeight($1) }
        return (0..<count).map { i in
            if let value = fixed[i] { return max(minimumFixed, value * scale) }
            guard weightSum > 0 else { return 0 }
            return remaining * (flexWeight(i) / weightSum)
        }
    }

    /// Distribute `total` (minus inter-cell `gap`s) across `weights` proportionally.
    private static func distribute(total: CGFloat, gap: CGFloat, weights: [CGFloat]) -> [CGFloat] {
        let count = weights.count
        guard count > 0 else { return [] }
        let available = total - gap * CGFloat(count - 1)
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 0, count: count) }
        return weights.map { available * ($0 / sum) }
    }

    /// Cumulative top-left offsets for consecutive `sizes` separated by `gap`.
    private static func offsets(of sizes: [CGFloat], gap: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        var accumulated: CGFloat = 0
        for size in sizes {
            result.append(accumulated)
            accumulated += size + gap
        }
        return result
    }
}
