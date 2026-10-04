import Foundation
import Testing

@testable import Ghostty

/// B-068: same-titled Terminals rows tell apart by a quiet ordinal suffix;
/// unique titles read unchanged.
struct LeoTerminalRowLabelTests {
    private func list(_ titles: String...) -> LeoTerminalList {
        titles.reduce(LeoTerminalList()) { $0.adding(LeoTerminalRow(id: UUID(), title: $1)) }
    }

    private func texts(_ list: LeoTerminalList) -> [String] { list.labels.map(\.text) }

    @Test func uniqueTitlesReadUnchanged() {
        let labels = list("~", "vim notes.txt", "~/src").labels

        #expect(labels.map(\.text) == ["~", "vim notes.txt", "~/src"])
        #expect(labels.allSatisfy { $0.suffix == nil })
    }

    @Test func sameTitledRowsNumberFromTheSecondInCreationOrder() {
        let labels = list("~", "~", "~").labels

        #expect(labels.map(\.title) == ["~", "~", "~"])
        #expect(labels.map(\.suffix) == [nil, "(2)", "(3)"])
        #expect(labels.map(\.text) == ["~", "~ (2)", "~ (3)"])
    }

    @Test func eachSharedTitleNumbersOnItsOwn() {
        #expect(texts(list("~", "src", "~", "vim", "src")) == ["~", "src", "~ (2)", "vim", "src (2)"])
    }

    @Test func untitledRowsTellApartToo() {
        #expect(texts(list("", "👻", "  ")) == ["Terminal", "Terminal (2)", "Terminal (3)"])
    }

    /// ...and read the same: no stray space before the title or the suffix.
    @Test func titlesThatOnlyDifferInSurroundingSpaceAreTheSame() {
        let labels = list("~", " ~ ").labels

        #expect(labels.map(\.title) == ["~", "~"])
        #expect(labels.map(\.text) == ["~", "~ (2)"])
    }

    /// B-079: the row's one tooltip reads its whole label, title and
    /// suffix, so hovering the "(2)" shows it too.
    @Test func theTooltipReadsTheWholeLabel() {
        let labels = list("~", " ~ ", "vim").labels

        #expect(labels.map(\.help) == ["~", "~ (2)", "vim"])
    }

    @Test func labelsFollowTheRowsInOrder() {
        let terminals = list("~", "~", "vim")

        #expect(terminals.labels.map(\.id) == terminals.rows.map(\.id))
    }

    /// A new shell is always listed last, so it never relabels an older row.
    @Test func aNewShellNeverRelabelsAnOlderRow() {
        let before = list("~", "vim", "~")
        let after = before.adding(LeoTerminalRow(id: UUID(), title: "~"))

        #expect(Array(after.labels.prefix(3)) == before.labels)
        #expect(after.labels.last?.text == "~ (3)")
    }

    @Test func aRowRetitledAwayFreesTheSharedTitle() {
        let terminals = list("~", "~")
        let first = terminals.rows[0].id

        #expect(texts(terminals.retitling(first, to: "vim")) == ["vim", "~"])
        #expect(texts(terminals.retitling(first, to: "vim").retitling(first, to: "~")) == ["~", "~ (2)"])
    }

    @Test func closingARowRenumbersOnlyItsTitle() {
        let terminals = list("~", "src", "~", "src", "~")

        #expect(texts(terminals.removing(terminals.rows[0].id)) == ["src", "~", "src (2)", "~ (2)"])
    }

    /// B-177: a row renamed to a title an older row shows numbers after it,
    /// as any retitle does; no row moves (D-132).
    @Test func aRenamedRowJoinsDuplicateNumbering() {
        let terminals = list("build", "~", "vim")
        let renamed = terminals.retitling(terminals.rows[2].id, to: "build")

        #expect(texts(renamed) == ["build", "~", "build (2)"])
        #expect(renamed.rows.map(\.id) == terminals.rows.map(\.id), "rows never move")
    }
}
