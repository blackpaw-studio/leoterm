import Combine
import Foundation

/// B-057 (D-099, D-111): one plain shell in its window's "Terminals"
/// sidebar section. The row owns its one surface for its whole life:
/// switching away hides it, and only closing it (⌘W, `exit`) ends it --
/// unless its pane closes beside a split, when a plain shell left there
/// carries it on in its sidebar slot (B-082).
struct LeoTerminalRow: Identifiable, Equatable, Sendable {
    /// The shell's surface (the one carrying the row on, after B-082).
    let id: UUID
    /// The terminal's own title (Ghostty's surface title), as it changes.
    let title: String

    /// What a row shows before its terminal has set a title.
    static let untitled = "Terminal"
    /// What Ghostty titles a surface whose terminal set none.
    static let ghosttyFallbackTitle = "👻"

    /// The title as the row shows it: without surrounding space (B-079),
    /// else "Terminal".
    var displayTitle: String { Self.displayTitle(of: title) }

    /// `title` as a row shows it (also what a close confirm names, B-088).
    static func displayTitle(of title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == ghosttyFallbackTitle ? untitled : trimmed
    }
}

/// A window's terminal rows, oldest first. Immutable: each change returns
/// a new list.
struct LeoTerminalList: Equatable, Sendable {
    let rows: [LeoTerminalRow]

    init(rows: [LeoTerminalRow] = []) { self.rows = rows }

    func contains(_ id: UUID) -> Bool { rows.contains { $0.id == id } }

    /// `row` last; a row already listed stays as it is.
    func adding(_ row: LeoTerminalRow) -> Self {
        contains(row.id) ? self : Self(rows: rows + [row])
    }

    func removing(_ id: UUID) -> Self { Self(rows: rows.filter { $0.id != id }) }

    /// `id`'s row carried on as `row`, in its place (B-082). A row already
    /// listed as `row` stays as it is, and `id`'s goes. Unchanged when `id`
    /// isn't listed.
    func replacing(_ id: UUID, with row: LeoTerminalRow) -> Self {
        guard contains(id) else { return self }
        if row.id != id && contains(row.id) { return removing(id) }
        return Self(rows: rows.map { $0.id == id ? row : $0 })
    }

    func retitling(_ id: UUID, to title: String) -> Self {
        Self(rows: rows.map { $0.id == id ? LeoTerminalRow(id: id, title: title) : $0 })
    }

    /// The row shown once `id` closes, as Finder and Mail pick one after a
    /// delete: the next row, else the previous one. `nil` when `id` is the
    /// only row, or isn't listed.
    func neighbour(of id: UUID) -> UUID? { neighbours(of: id).first }

    /// Every other row, in the order one is picked to show once `id`
    /// closes: the rows after it, nearest first, then those before it,
    /// nearest first -- so a neighbour with nothing to show is passed over
    /// for the next. Empty when `id` isn't listed.
    func neighbours(of id: UUID) -> [UUID] {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return [] }
        return (rows[(index + 1)...] + rows[..<index].reversed()).map(\.id)
    }
}

/// One window's terminal rows and which of them its sidebar selects (per
/// window: a shell lives in the window that made it, while the agent list
/// and its selection are app-wide in `LeoSidebarModel`). Owned by the
/// window's `LeoWindowSession`; the attach host adds, retitles and removes
/// rows as their surfaces come and go.
@MainActor final class LeoWindowTerminals: ObservableObject {
    @Published private(set) var list = LeoTerminalList()
    /// The terminal row this window's sidebar selects; `nil` when an agent
    /// row (or nothing) is selected there.
    @Published private(set) var selection: UUID?
    /// Shows the row in the window's content area (wired by `LeoRuntime`).
    var showRequested: (UUID) -> Void = { _ in }
    /// Closes the shown row: its neighbour shows instead, or the start
    /// screen (wired by `LeoRuntime`). Asked by `TerminalController` once
    /// Ghostty's own close (and its busy-process confirm) has decided.
    var closeRequested: (UUID) -> Void = { _ in }
    /// Whether a shell this window keeps hidden has a running process, so
    /// closing the window asks first (wired by `LeoRuntime`).
    var hasBusyHiddenShell: () -> Bool = { false }
    /// B-177: the row's context menu, wired by `LeoRuntime` as the rest.
    /// Rename… titles the row's shell; an empty name restores its own title.
    var renameRequested: (UUID, String) -> Void = { _, _ in }
    /// Split Right / Split Down: the row shows, then splits beside its shell.
    var splitRequested: (UUID, LeoSplitDirection) -> Void = { _, _ in }
    /// Close, asking first as ⌘W does when a process is running.
    var closeFromMenuRequested: (UUID) -> Void = { _ in }
    /// The terminal's own title under any name given to the row (what
    /// Rename… restores when left blank).
    var liveTitle: (UUID) -> String? = { _ in nil }

    var rows: [LeoTerminalRow] { list.rows }

    func contains(_ id: UUID) -> Bool { list.contains(id) }

    func add(_ id: UUID, title: String) {
        update(list.adding(LeoTerminalRow(id: id, title: title)))
    }

    func retitle(_ id: UUID, to title: String) {
        update(list.retitling(id, to: title))
    }

    /// B-082: `id`'s row carries on as `newID`'s shell, in its slot; a
    /// selection on it moves along. Nothing changes when `id` isn't listed.
    func replace(_ id: UUID, with newID: UUID, title: String) {
        guard contains(id) else { return }
        update(list.replacing(id, with: LeoTerminalRow(id: newID, title: title)))
        if selection == id { selection = newID }
    }

    /// The row is gone (its shell closed); so is its selection.
    func remove(_ id: UUID) {
        update(list.removing(id))
        if selection == id { selection = nil }
    }

    /// Selects a row this window holds, or none.
    func select(_ id: UUID?) {
        let selected = id.flatMap { contains($0) ? $0 : nil }
        guard selected != selection else { return }
        selection = selected
    }

    /// A click on the row, or Return with it selected: select and show it.
    func activate(_ id: UUID) {
        guard contains(id) else { return }
        select(id)
        showRequested(id)
    }

    // MARK: The row's menu (B-177). Each acts only on a row this window
    // lists, and none of them moves the selection by itself.

    func rename(_ id: UUID, to name: String) {
        guard contains(id) else { return }
        renameRequested(id, name)
    }

    func split(_ id: UUID, _ direction: LeoSplitDirection) {
        guard contains(id) else { return }
        splitRequested(id, direction)
    }

    func closeFromMenu(_ id: UUID) {
        guard contains(id) else { return }
        closeFromMenuRequested(id)
    }

    /// Publishes only real changes: a title the terminal sets again
    /// redraws nothing.
    private func update(_ updated: LeoTerminalList) {
        guard updated != list else { return }
        list = updated
    }
}
