import Foundation
import Testing

@testable import Ghostty

/// The binary / large-file guard: what opens editable, what opens
/// read-only (with the notice's reason), and what doesn't open at all.
struct LeoEditorContentPolicyTests {
    private let policy = LeoEditorContentPolicy(editableLimit: 10, readLimit: 20)

    @Test func theDefaultsAreFiveMegabytesEditable() {
        #expect(LeoEditorContentPolicy.default.editableLimit == 5_000_000)
        #expect(LeoEditorContentPolicy.default.readLimit > LeoEditorContentPolicy.default.editableLimit)
    }

    @Test func utf8TextIsEditable() {
        let content = policy.evaluate(Data("héllo\r\n".utf8))
        #expect(content == LeoEditorContent(text: "héllo\r\n", readOnlyReason: nil))
    }

    @Test func anEmptyFileIsEditable() {
        #expect(policy.evaluate(Data()) == LeoEditorContent(text: "", readOnlyReason: nil))
    }

    @Test func aByteOrderMarkSurvivesTheRoundTrip() {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("x".utf8)
        let content = policy.evaluate(bytes)
        #expect(content.readOnlyReason == nil)
        #expect(content.encoded() == bytes)
    }

    @Test func exactlyTheEditableLimitIsStillEditable() {
        #expect(policy.evaluate(Data(repeating: 0x61, count: 10)).readOnlyReason == nil)
    }

    @Test func overTheEditableLimitIsReadOnly() {
        let content = policy.evaluate(Data(repeating: 0x61, count: 11))
        #expect(content.readOnlyReason == .tooLarge(size: 11, limit: 10))
        #expect(content.text.count == 11)
    }

    @Test func aNulByteNearTheStartIsBinary() {
        let content = policy.evaluate(Data([0x61, 0x00, 0x62]))
        #expect(content.readOnlyReason == .binary)
    }

    /// Like git: only the first 8000 bytes are sniffed for NUL.
    @Test func onlyTheStartIsSniffedForBinary() {
        let late = LeoEditorContentPolicy(editableLimit: 10_000, readLimit: 20_000)
        let bytes = Data(repeating: 0x61, count: 8000) + Data([0x00])
        #expect(late.evaluate(bytes).readOnlyReason == nil)
    }

    @Test func invalidUTF8IsReadOnly() {
        let content = policy.evaluate(Data([0x61, 0xFF, 0x62]))
        #expect(content.readOnlyReason == .notUTF8)
        #expect(content.text == "a\u{FFFD}b")
    }

    @Test func noticesReadAsSentences() {
        #expect(LeoEditorReadOnlyReason.binary.notice == "This file looks binary, so it’s read-only.")
        #expect(LeoEditorReadOnlyReason.notUTF8.notice == "This file isn’t UTF-8 text, so it’s read-only.")
        #expect(LeoEditorReadOnlyReason.tooLarge(size: 6_000_000, limit: 5_000_000).notice
            == "This file is larger than 5 MB, so it’s read-only.")
    }
}
