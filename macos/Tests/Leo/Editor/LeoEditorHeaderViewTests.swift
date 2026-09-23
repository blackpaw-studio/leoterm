import AppKit
import Testing

@testable import Ghostty

/// A file's name and folder come from terminal output or the remote host,
/// so the header shows them only sanitized: no bidi overrides, control
/// characters or newlines in the recents menu, its tooltips or the
/// accessibility label.
@MainActor
struct LeoEditorHeaderViewTests {
    private static let hostile = LeoEditorFileID(host: .local, path: "/tmp/in\u{202E}box\n\u{7}/re\u{202E}port\u{0}\n.txt")
    private static let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{202E}\u{200B}\n"))

    private func isSafe(_ text: String) -> Bool {
        text.rangeOfCharacter(from: Self.unsafe) == nil
    }

    @Test func theNameIsSanitized() {
        let title = LeoEditorHeaderView.title(for: Self.hostile)

        #expect(isSafe(title))
        #expect(title == "report .txt")
    }

    @Test func theFolderIsSanitized() {
        #expect(isSafe(LeoEditorHeaderView.location(of: Self.hostile)))
        #expect(isSafe(LeoEditorHeaderView.menuTitle(for: Self.hostile).string))
    }

    @Test func theAccessibilityLabelIsSanitized() {
        let label = LeoEditorHeaderView.accessibilityLabel(forOpen: Self.hostile)

        #expect(isSafe(label))
        #expect(label == "Open file: report .txt")
        #expect(LeoEditorHeaderView.accessibilityLabel(forOpen: nil) == "Recent files")
    }
}
