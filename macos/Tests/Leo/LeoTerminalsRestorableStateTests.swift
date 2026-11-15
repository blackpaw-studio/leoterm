import AppKit
import Testing

@testable import Ghostty

/// B-332: what a Leo window saves for restoring its Terminals rows at
/// launch, and what it restores from that.
@MainActor struct LeoTerminalsRestorableStateTests {
    private typealias State = LeoTerminalsRestorableState.InternalState<MockView>
    private typealias Row = LeoTerminalsRestorableState.RowState<MockView>
    private typealias Tree = SplitTree<MockView>

    /// Every row comes back in sidebar order, each with its layout's
    /// shape -- direction, ratio, zoom -- its focused pane, and the
    /// window's selection.
    @Test func roundTripsRowsInSidebarOrder() throws {
        let (a1, a2, a3, b) = (MockView(), MockView(), MockView(), MockView())
        let column = Tree.Node.split(.init(direction: .vertical, ratio: 0.7, left: .leaf(view: a2), right: .leaf(view: a3)))
        let layout = Tree(
            root: .split(.init(direction: .horizontal, ratio: 0.3, left: .leaf(view: a1), right: column)),
            zoomed: .leaf(view: a2)
        )
        let saved = State(
            rows: [Row(id: b.id, layout: Tree(view: b), focusedPane: b.id), Row(id: a1.id, layout: layout, focusedPane: a3.id)],
            selectedRow: a1.id
        )

        let restored = try Self.roundTrip(saved)

        #expect(restored.rows.map(\.id) == [b.id, a1.id])
        #expect(restored.rows.map(\.focusedPane) == [b.id, a3.id])
        #expect(restored.selectedRow == a1.id)
        #expect(restored.rows.map { Self.shape($0.layout) } == saved.rows.map { Self.shape($0.layout) })
        #expect(Self.shape(restored.rows[1].layout).hasSuffix("zoom=\(a2.id)"), "the zoom survives")
    }

    /// A pre-Leo window's saved state never reads as a Leo window's.
    @Test func oldTerminalStateDoesNotDecode() throws {
        let view = MockView()
        let old = OldTerminalStateDummy(.init(
            focusedSurface: view.id.uuidString, surfaceTree: Tree(view: view),
            effectiveFullscreenMode: nil, tabColor: nil, titleOverride: "old"
        ))
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        old.encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        defer { unarchiver.finishDecoding() }

        #expect(LeoTerminalsStateDummy(coder: unarchiver) == nil)
    }

    /// Only plain shells are saved: an agent's pane (it reattaches through
    /// tmux) and a pane whose process ended leave their layout. A row
    /// whose own pane leaves passes to the pane its layout focuses, else
    /// its first (D-191), its selection with it; a row left with no pane
    /// is not saved.
    @Test func snapshotDropsAgentAndExitedPanes() throws {
        let (shell, agent) = (MockView(), MockView())
        let ended = MockView()
        let (endedRow, survivor) = (MockView(), MockView())
        let unsaved: Set<UUID> = [agent.id, ended.id, endedRow.id]
        let layouts = [
            LeoTerminalRowLayout(row: shell, layout: try Tree(view: shell).inserting(view: agent, at: shell, direction: .right), focused: agent),
            LeoTerminalRowLayout(row: ended, layout: Tree(view: ended), focused: ended),
            LeoTerminalRowLayout(row: endedRow, layout: try Tree(view: endedRow).inserting(view: survivor, at: endedRow, direction: .down), focused: endedRow),
        ]

        let state = State.snapshot(layouts, selected: endedRow.id) { !unsaved.contains($0.id) }

        #expect(state.rows.map(\.id) == [shell.id, survivor.id])
        #expect(state.rows.map { $0.layout.map(\.id) } == [[shell.id], [survivor.id]])
        #expect(state.rows.map(\.focusedPane) == [shell.id, survivor.id])
        #expect(state.selectedRow == survivor.id)
    }

    /// The selection is saved only while it names a saved row.
    @Test func snapshotDropsASelectionOfNoSavedRow() {
        let (shell, ended) = (MockView(), MockView())
        let layouts = [
            LeoTerminalRowLayout(row: shell, layout: Tree(view: shell), focused: shell),
            LeoTerminalRowLayout(row: ended, layout: Tree(view: ended), focused: nil),
        ]

        #expect(State.snapshot(layouts, selected: ended.id) { $0 !== ended }.selectedRow == nil)
        #expect(State.snapshot(layouts, selected: nil) { _ in true }.selectedRow == nil)
        #expect(State.snapshot(layouts, selected: nil) { _ in true }.rows.map(\.focusedPane) == [shell.id, ended.id])
    }

    /// A restored window shows the row selected at quit, else -- an agent
    /// was selected, or none -- its first row.
    @Test(arguments: [nil, UUID()] as [UUID?])
    func selectionFallsBackToFirstRow(_ selected: UUID?) {
        let rows = [UUID(), UUID()]

        #expect(LeoTerminalsRestorableState.shownRow(of: rows, selected: selected) == rows[0])
        #expect(LeoTerminalsRestorableState.shownRow(of: rows, selected: rows[1]) == rows[1])
        #expect(LeoTerminalsRestorableState.shownRow(of: [], selected: selected) == nil)
    }

    @Test func versionGuard() {
        #expect(LeoTerminalsRestorableState.version == 1)
        #expect(LeoTerminalsRestorableState.minimumVersion == 1)
        #expect(LeoTerminalsRestorableState.selfKey != TerminalRestorableState.selfKey)
        #expect(LeoTerminalsRestorableState.versionKey != TerminalRestorableState.versionKey)
    }

    private static func roundTrip(_ state: State) throws -> State {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        LeoTerminalsStateDummy(state).encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        defer { unarchiver.finishDecoding() }
        return try #require(LeoTerminalsStateDummy(coder: unarchiver)).internalState
    }

    /// A tree's shape by view ids: each split's direction and ratio, and
    /// what is zoomed.
    private static func shape(_ tree: Tree) -> String {
        let zoom = tree.zoomed.map { " zoom=\(shape($0))" } ?? ""
        return (tree.root.map(shape) ?? "empty") + zoom
    }

    private static func shape(_ node: Tree.Node) -> String {
        switch node {
        case .leaf(let view): "\(view.id)"
        case .split(let split): "\(split.direction)(\(split.ratio))[\(shape(split.left)), \(shape(split.right))]"
        }
    }
}

/// `LeoTerminalsRestorableState`'s coding, over `MockView`s.
final class LeoTerminalsStateDummy: TerminalRestorable {
    static var version: Int { LeoTerminalsRestorableState.version }
    static var minimumVersion: Int { LeoTerminalsRestorableState.minimumVersion }
    static var selfKey: String { LeoTerminalsRestorableState.selfKey }
    static var versionKey: String { LeoTerminalsRestorableState.versionKey }

    let internalState: LeoTerminalsRestorableState.InternalState<MockView>

    init(_ internalState: LeoTerminalsRestorableState.InternalState<MockView>) { self.internalState = internalState }
    required init(copy other: LeoTerminalsStateDummy) { internalState = other.internalState }
    required init(from decoder: any Decoder) throws { internalState = try .init(from: decoder) }
    func encode(to encoder: any Encoder) throws { try internalState.encode(to: encoder) }
}

/// Upstream's `TerminalRestorableState` coding (v7), over `MockView`s.
final class OldTerminalStateDummy: TerminalRestorable {
    static var version: Int { TerminalRestorableState.version }
    static var minimumVersion: Int { TerminalRestorableState.minimumVersion }

    let internalState: TerminalRestorableState.InternalState<MockView>

    init(_ internalState: TerminalRestorableState.InternalState<MockView>) { self.internalState = internalState }
    required init(copy other: OldTerminalStateDummy) { internalState = other.internalState }
    required init(from decoder: any Decoder) throws { internalState = try .init(from: decoder) }
    func encode(to encoder: any Encoder) throws { try internalState.encode(to: encoder) }
}
