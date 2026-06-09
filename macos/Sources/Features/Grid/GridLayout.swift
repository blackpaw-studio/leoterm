import Foundation

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
        let n = cells.count
        guard n > 0, size.width > 0, size.height > 0 else { return [] }
        let (rows, columns) = Self.dimensions(forCount: n)

        let emphasizedIndex = emphasizedID.flatMap { id in cells.firstIndex { $0.id == id } }
        let emphasizedRow = emphasizedIndex.map { $0 / columns }
        let g = max(1, factor)

        let rowWeights = (0..<rows).map { r in (r == emphasizedRow) ? g : 1 }
        let rowHeights = Self.distribute(total: size.height, gap: gap, weights: rowWeights)
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
