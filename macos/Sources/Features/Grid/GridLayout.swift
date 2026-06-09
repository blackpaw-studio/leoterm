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
