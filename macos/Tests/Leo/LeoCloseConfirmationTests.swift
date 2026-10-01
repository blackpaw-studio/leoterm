import Foundation
import Testing

@testable import Ghostty

/// B-088: the "Close …?" confirm names the pane or row it closes, as its
/// window title and sidebar row name it, so a busy split beside another
/// isn't ambiguous.
struct LeoCloseConfirmationTests {
    // MARK: A pane's name

    struct Titled: Sendable, CustomTestStringConvertible {
        let title: String
        var isUserSet = false
        var agentName: String?
        let name: String

        var testDescription: String { "\(title.debugDescription) → \(name)" }
    }

    @Test(arguments: [
        // The terminal's own title.
        Titled(title: "~/src/leo", name: "~/src/leo"),
        // An attach shows its agent's name, whatever the terminal set.
        Titled(title: "tmux", agentName: "worker", name: "worker"),
        // A title the user set wins over the agent's name.
        Titled(title: "deploy", isUserSet: true, agentName: "worker", name: "deploy"),
        // Untitled, as the sidebar row reads it.
        Titled(title: "", name: "Terminal"),
        Titled(title: "  ", name: "Terminal"),
        Titled(title: "👻", name: "Terminal"),
        Titled(title: " vim \n", name: "vim"),
    ])
    func aPaneIsNamedAsItsTitleShowsIt(_ titled: Titled) {
        #expect(LeoCloseConfirmation.name(title: titled.title, isUserSet: titled.isUserSet, agentName: titled.agentName) == titled.name)
    }

    /// A title is whatever the terminal sent (OSC 0/2): control characters
    /// can't break the alert's line.
    @Test func controlCharactersInATitleBecomeSpaces() {
        #expect(LeoCloseConfirmation.name(title: "make\u{1B}\ttest\r\nall", isUserSet: false, agentName: nil) == "make test all")
    }

    /// A long title keeps both ends -- a path's last directory included.
    @Test func aLongTitleIsShortenedInTheMiddle() {
        let title = "evan@dionysus: ~/" + String(repeating: "x", count: 100) + "/lanes/B-088"

        let name = LeoCloseConfirmation.name(title: title, isUserSet: false, agentName: nil)

        #expect(name.count == LeoCloseConfirmation.maxNameLength)
        #expect(name.hasPrefix("evan@dionysus: ~/"))
        #expect(name.hasSuffix("/lanes/B-088"))
        #expect(name.contains("…"))
    }

    @Test func aTitleAtTheLimitIsKeptWhole() {
        let title = String(repeating: "a", count: LeoCloseConfirmation.maxNameLength)

        #expect(LeoCloseConfirmation.name(title: title, isUserSet: false, agentName: nil) == title)
    }

    // MARK: The message

    @Test(arguments: [
        (["build"], "Close “build”?"),
        (["build", "server"], "Close “build” and “server”?"),
        (["build", "server", "logs"], "Close “build” and 2 other terminals?"),
        ([], "Close Terminal?"),
    ])
    func theMessageNamesWhatCloses(_ names: [String], _ message: String) {
        #expect(LeoCloseConfirmation.messageText(closing: names) == message)
    }

    /// Beside a split, the confirm says only that pane closes.
    @Test func aSplitPanesConfirmSaysTheOtherSplitsStay() {
        #expect(LeoCloseConfirmation.paneInformativeText.contains("other splits stay open"))
    }

    // MARK: Switching away from a busy split (D-106)

    @Test func switchingAwayNamesEachBusyShellThatCloses() {
        let shown = [
            LeoContentReplacement.Shown(name: "worker", isAgent: true, needsConfirmQuit: true),
            .init(name: "~/src", isAgent: false, isTerminalRow: true, needsConfirmQuit: false),
            .init(name: "build", isAgent: false, needsConfirmQuit: true),
        ]

        #expect(LeoContentReplacement.messageText(shown) == "Close “build”?")
    }
}
