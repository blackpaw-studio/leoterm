import Foundation
import Testing

@testable import Ghostty

/// B-013: the daemon's `file_surfaced` SSE event and `/state`'s per-agent
/// `surfaced_files`, decoded leniently -- an old daemon sends neither, and
/// a malformed entry is dropped rather than failing its parent.
struct LeoSurfacedFileDecodingTests {
    private static let full = #"""
    {"type":"file_surfaced","seq":7,"agent":"alpha","started_at":"s1","id":"u-1","path":"src/main.swift","abs_path":"/w/alpha/src/main.swift","line":12,"reason":"Fixed the crash","at":"2026-09-24T15:00:00Z"}
    """#

    private func decode(_ name: String?, _ json: String) -> LeoObserveEvent? {
        var parser = LeoSSEParser()
        let header = name.map { "event: \($0)\n" } ?? ""
        return parser.feed(Data("\(header)data: \(json)\n\n".utf8)).compactMap(LeoActivityClient.decode).first
    }

    @Test func decodesAFullEvent() throws {
        let event = try #require(decode("file_surfaced", Self.full))
        guard case .fileSurfaced(let seq, let file) = event else {
            Issue.record("expected fileSurfaced, got \(event)")
            return
        }
        #expect(seq == 7)
        #expect(event.sequence == 7)
        #expect(file == LeoSurfacedFile(
            id: "u-1", agent: "alpha", startedAt: "s1", path: "src/main.swift", absPath: "/w/alpha/src/main.swift",
            line: 12, reason: "Fixed the crash", at: "2026-09-24T15:00:00Z"
        ))
    }

    @Test func lineAndReasonAreOptional() throws {
        let json = #"{"agent":"alpha","started_at":"s1","id":"u-2","path":"a.txt","abs_path":"/w/a.txt","at":"2026-09-24T15:00:00Z"}"#
        guard case .fileSurfaced(let seq, let file) = try #require(decode("file_surfaced", json)) else {
            Issue.record("not decoded")
            return
        }
        #expect(seq == nil)
        #expect(file.line == nil)
        #expect(file.reason == nil)
    }

    @Test func theTypeFieldNamesAnUnnamedEvent() throws {
        guard case .fileSurfaced(_, let file) = try #require(decode(nil, Self.full)) else {
            Issue.record("not decoded")
            return
        }
        #expect(file.id == "u-1")
    }

    @Test(arguments: [
        #"{"started_at":"s1","id":"u","path":"a","abs_path":"/a"}"#,
        #"{"agent":"alpha","id":"u","path":"a","abs_path":"/a"}"#,
        #"{"agent":"alpha","started_at":"s1","path":"a","abs_path":"/a"}"#,
        #"{"agent":"alpha","started_at":"s1","id":"","path":"a","abs_path":"/a"}"#,
        #"{"agent":"alpha","started_at":"s1","id":"u","path":"a"}"#,
        #"{"agent":"alpha","started_at":"s1","id":"u","path":"a","abs_path":"relative/a"}"#,
    ])
    func anEventMissingItsIdentityIsDropped(json: String) {
        #expect(decode("file_surfaced", json) == nil)
    }

    @Test func aBadLineOrReasonDegradesToAbsent() throws {
        let json = #"{"agent":"alpha","started_at":"s1","id":"u","path":"a","abs_path":"/a","line":0,"reason":42}"#
        guard case .fileSurfaced(_, let file) = try #require(decode("file_surfaced", json)) else {
            Issue.record("not decoded")
            return
        }
        #expect(file.line == nil)
        #expect(file.reason == nil)
    }

    @Test func stateCarriesSurfacedFilesNewestLast() throws {
        let json = #"""
        {"name":"alpha","started_at":"s1","surfaced_files":[
          {"agent":"alpha","started_at":"s1","id":"u-1","path":"a","abs_path":"/a","at":"2026-09-24T15:00:00Z"},
          {"agent":"alpha","started_at":"s1","id":"broken"},
          "not an object",
          {"agent":"alpha","started_at":"s1","id":"u-2","path":"b","abs_path":"/b","line":3,"reason":"why"}
        ]}
        """#
        let agent = try JSONDecoder().decode(LeoObservedAgent.self, from: Data(json.utf8))
        #expect(agent.surfacedFiles.map(\.id) == ["u-1", "u-2"], "a malformed entry is dropped, not the payload")
        #expect(agent.surfacedFiles.last?.line == 3)
    }

    @Test func anOldDaemonsStateHasNoSurfacedFiles() throws {
        let agent = try JSONDecoder().decode(LeoObservedAgent.self, from: Data(#"{"name":"alpha","started_at":"s1"}"#.utf8))
        #expect(agent.surfacedFiles.isEmpty)
        let wrongShape = try JSONDecoder().decode(LeoObservedAgent.self, from: Data(#"{"name":"alpha","surfaced_files":"nope"}"#.utf8))
        #expect(wrongShape.surfacedFiles.isEmpty)
    }

    /// A seq-less event must not reset gap detection: the next numbered
    /// event after it is not a gap.
    @Test func aSeqlessEventHasNoSequence() {
        let file = LeoSurfacedFile(id: "u", agent: "a", startedAt: "s", path: "p", absPath: "/p")
        #expect(LeoObserveEvent.fileSurfaced(seq: nil, file: file).sequence < 0)
    }

    @Test func displayTextIsSanitized() {
        let file = LeoSurfacedFile(
            id: "u", agent: "a", startedAt: "s", path: "src/\u{1B}[31mevil\u{202E}.swift", absPath: "/p",
            reason: "Look\u{0007} here\n\u{1B}]0;title\u{07}"
        )
        #expect(!file.displayName.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == "\u{202E}" })
        #expect(file.displayName.hasSuffix(".swift"))
        #expect(!(file.displayReason ?? "").unicodeScalars.contains { $0.properties.generalCategory == .control })
        #expect(file.menuTitle.contains(" — "))
        let bare = LeoSurfacedFile(id: "u", agent: "a", startedAt: "s", path: "dir/notes.md", absPath: "/p", reason: "  ")
        #expect(bare.displayReason == nil)
        #expect(bare.menuTitle == "notes.md")
    }
}
