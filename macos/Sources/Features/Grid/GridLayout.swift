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
