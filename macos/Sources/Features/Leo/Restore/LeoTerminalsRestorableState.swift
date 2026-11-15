import AppKit

/// B-332: what a Leo window saves through AppKit state restoration, as a
/// Ghostty window saves its tabs (`window-save-state`): its Terminals rows
/// in sidebar order, each with its whole split layout -- shown or kept
/// hidden, the row owning it (D-631) -- and the pane focused in it, and
/// the row its sidebar selects. Only running plain shells are saved: an
/// agent's pane reattaches through tmux, and an exited pane has nothing to
/// come back to. Each surface saves its title and working directory
/// (`Ghostty.SurfaceView`'s coding), never its contents.
///
/// Restored by `LeoTerminalWindowRestoration`. Keys of its own, so a
/// pre-Leo `TerminalRestorableState` never reads as one.
final class LeoTerminalsRestorableState: TerminalRestorable {
    typealias Row = RowState<Ghostty.SurfaceView>

    static var version: Int { 1 }
    static var minimumVersion: Int { 1 }
    static var selfKey: String { "leoTerminals" }
    static var versionKey: String { "leoTerminalsVersion" }

    var rows: [Row] { internalState.rows }
    var selectedRow: UUID? { internalState.selectedRow }

    /// The coded state, generic so tests can code it over mock views (see
    /// `TerminalRestorableState`'s).
    private let internalState: InternalState<Ghostty.SurfaceView>

    init(_ internalState: InternalState<Ghostty.SurfaceView>) { self.internalState = internalState }
    required init(copy other: LeoTerminalsRestorableState) { internalState = other.internalState }
    init(from decoder: any Decoder) throws { internalState = try .init(from: decoder) }
    func encode(to encoder: any Encoder) throws { try internalState.encode(to: encoder) }

    /// The row a restored window shows: the one selected at quit, else --
    /// an agent was selected, or nothing -- its first.
    static func shownRow(of rows: [UUID], selected: UUID?) -> UUID? {
        rows.first { $0 == selected } ?? rows.first
    }
}

extension LeoTerminalsRestorableState {
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        /// In sidebar order.
        let rows: [RowState<ViewType>]
        /// The row the sidebar selected; `nil` for an agent, or none.
        let selectedRow: UUID?
    }

    struct RowState<ViewType: NSView & Codable & Identifiable>: Codable {
        /// The row's own shell: the surface its sidebar row is keyed by.
        let id: UUID
        let layout: SplitTree<ViewType>
        let focusedPane: UUID?
    }
}

extension LeoTerminalsRestorableState.InternalState where ViewType.ID == UUID {
    /// `layouts`, in sidebar order, less each pane `isSaved` turns down. A
    /// row whose own pane goes passes to the pane its layout focuses, else
    /// its first (D-191) -- `selected` with it -- and a row left with no
    /// pane isn't saved, nor is a selection of it.
    static func snapshot(
        _ layouts: [LeoTerminalRowLayout<ViewType>],
        selected: UUID?,
        saving isSaved: (ViewType) -> Bool
    ) -> Self {
        let saved = layouts.map { ($0.row.id, row(of: $0, saving: isSaved)) }
        return .init(
            rows: saved.compactMap(\.1),
            selectedRow: saved.first { $0.0 == selected }?.1?.id
        )
    }

    private static func row(of layout: LeoTerminalRowLayout<ViewType>, saving isSaved: (ViewType) -> Bool) -> LeoTerminalsRestorableState.RowState<ViewType>? {
        let tree = layout.layout.filter { !isSaved($0) }.reduce(layout.layout) { tree, pane in
            tree.root?.node(view: pane).map(tree.removing) ?? tree
        }
        guard let first = tree.first else { return nil }
        let surviving: (ViewType?) -> ViewType? = { pane in pane.flatMap { pane in tree.contains { $0 === pane } ? pane : nil } }
        let focused = surviving(layout.focused)
        let row = surviving(layout.row) ?? focused ?? first
        return .init(id: row.id, layout: tree, focusedPane: (focused ?? row).id)
    }
}

/// B-332: one terminal row's layout as the attach host holds it: `row`,
/// the row's own shell, and the pane `layout` has focused.
struct LeoTerminalRowLayout<ViewType: NSView & Codable & Identifiable> {
    let row: ViewType
    let layout: SplitTree<ViewType>
    let focused: ViewType?
}
