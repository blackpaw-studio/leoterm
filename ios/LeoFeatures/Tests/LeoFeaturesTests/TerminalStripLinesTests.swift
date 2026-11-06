import Testing

@testable import LeoFeatures

struct TerminalStripLinesTests {
    private static let status = "[leo] 0:claude*                                 \"leoterm\" 07:58 31-Oct"
    private static let rule = String(repeating: "─", count: 78)

    /// A Claude Code screen as it draws today: a labelled rule above the prompt,
    /// a rule below it, a status panel with a closing rule of its own, then
    /// tmux's status row.
    private static let claudeScreen = [
        "● Read(src/main.zig)",
        "  ⎿  Read 120 lines",
        "",
        "● The build is green.",
        "  I changed two files.",
        "",
        "● Next I will run the tests.",
        "",
        String(repeating: "─", count: 66) + " leoterm ─",
        "❯ ",
        rule,
        "  ⏵⏵ auto mode on (shift+tab to cycle)",
        "",
        "  model   Sonnet 5.5  ·  thinking medium",
        "  where   /p/t/c/c/app  ·  no git  ·  no PR",
        "  context ▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆▆  —",
        "          sys 2.9k  tools 39k  mem 11k  chat 17k  · 931k free  · compact 37%",
        "  cost    $0.04",
        "  " + rule,
        status,
    ]

    @Test func showsTheFiveNonBlankRowsAboveClaudeCodesInputBox() {
        #expect(TerminalStripLines.rows(Self.claudeScreen, count: 5) == [
            "  ⎿  Read 120 lines", "● The build is green.", "  I changed two files.", "● Next I will run the tests.",
        ].prepending("● Read(src/main.zig)"))
    }

    @Test func blankRowsAreSkippedNotCounted() {
        #expect(TerminalStripLines.rows(Self.claudeScreen, count: 3) == [
            "● The build is green.", "  I changed two files.", "● Next I will run the tests.",
        ])
    }

    @Test func aRoundedBoxIsFoundByItsTopBorder() {
        let screen = [
            "● one", "● two", "● three",
            "╭" + String(repeating: "─", count: 76) + "╮",
            "│ > Try \"fix the failing test\"" + String(repeating: " ", count: 49) + "│",
            "╰" + String(repeating: "─", count: 76) + "╯",
            "  ? for shortcuts",
            Self.status,
        ]
        #expect(TerminalStripLines.rows(screen, count: 5) == ["● one", "● two", "● three"])
    }

    @Test func aMultiLineInputKeepsTheBoxTopAsTheBoundary() {
        let screen = ["● done", Self.rule, "❯ line one", "  line two", "  line three", Self.rule, "  ? for shortcuts", Self.status]
        #expect(TerminalStripLines.rows(screen, count: 5) == ["● done"])
    }

    @Test func aRuleInTheOutputAboveTheBoxIsNotTheBoundary() {
        let screen = ["● before", Self.rule, "● after", "", Self.rule, "❯ ", Self.rule, "  ? for shortcuts", Self.status]
        #expect(TerminalStripLines.rows(screen, count: 5) == ["● before", Self.rule, "● after"])
    }

    @Test func withoutABoxItShowsTheBottomRowsWithTheStatusRowDropped() {
        let screen = ["a", "b", "c", "d", "e", "f", "", "", Self.status]
        #expect(TerminalStripLines.rows(screen, count: 5) == ["b", "c", "d", "e", "f"])
    }

    @Test func aBoxWithNothingAboveItShowsNothing() {
        #expect(TerminalStripLines.rows([Self.rule, "❯ ", Self.rule, Self.status], count: 5).isEmpty)
    }

    @Test func aBlankScreenHasNoLines() {
        #expect(TerminalStripLines.rows(["", "  ", Self.status], count: 5).isEmpty)
        #expect(TerminalStripLines.rows([], count: 5).isEmpty)
        #expect(TerminalStripLines.rows([Self.status], count: 5).isEmpty)
    }

    @Test func rowsKeepTheirLeadingIndent() {
        #expect(TerminalStripLines.rows(["  indented", "", "end", Self.status], count: 3) == ["  indented", "end"])
    }

    @Test func emptyTerminalCellsBecomeSpaces() {
        // The emulator reports a cell nothing was drawn in as NUL; a label stops reading at one.
        #expect(TerminalStripLines.rows(["\0\0cost\0\0$0", Self.status], count: 5) == ["  cost  $0"])
    }
}

private extension [String] {
    func prepending(_ row: String) -> [String] { [row] + self }
}
