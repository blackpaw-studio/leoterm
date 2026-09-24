import Foundation

/// What Escape in the sidebar's search field should do next.
enum LeoSidebarSearchEscape: Equatable {
    /// The filter had text and is now empty; focus stays in the field.
    case cleared
    /// The filter was already empty; focus goes back to the terminal.
    case leaveField
}

/// B-009: the sidebar filter's keyboard behaviour.
extension LeoSidebarModel {
    /// Name characters to draw bold for the current query.
    func searchHighlights(for row: LeoAgentRow) -> [Int] {
        LeoFuzzyMatcher.nameHighlights(for: row, query: query)
    }

    func searchEscape() -> LeoSidebarSearchEscape {
        guard !query.isEmpty else { return .leaveField }
        query = ""
        return .cleared
    }

    /// Return: the same as clicking the top-ranked row. Inert while
    /// disconnected, like the rows themselves (D-061).
    func searchSubmit() {
        guard !isDisconnected, let top = visibleRows.first else { return }
        rowClicked(top)
    }
}
