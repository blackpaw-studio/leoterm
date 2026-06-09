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
    /// The frame for each cell within `size`, separated by `gap`, in display order.
    ///
    /// Cells fill row-major. Rows split the height equally. Within a row, cells
    /// split that row's width equally; the last (possibly partial) row stretches
    /// its cells across the full width. Origin is top-left (y grows downward).
    /// Returns an empty array for an empty layout or a non-positive `size`.
    func frames(in size: CGSize, gap: CGFloat = 0) -> [(cell: ViewType, frame: CGRect)] {
        let n = cells.count
        guard n > 0, size.width > 0, size.height > 0 else { return [] }

        let (rows, columns) = Self.dimensions(forCount: n)
        let rowHeight = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        var result: [(cell: ViewType, frame: CGRect)] = []
        result.reserveCapacity(n)
        for index in 0..<n {
            let row = index / columns
            let col = index % columns
            let isLastRow = row == rows - 1
            let cellsInRow = isLastRow ? (n - row * columns) : columns
            let colWidth = (size.width - gap * CGFloat(cellsInRow - 1)) / CGFloat(cellsInRow)
            let frame = CGRect(
                x: CGFloat(col) * (colWidth + gap),
                y: CGFloat(row) * (rowHeight + gap),
                width: colWidth,
                height: rowHeight)
            result.append((cells[index], frame))
        }
        return result
    }
}
