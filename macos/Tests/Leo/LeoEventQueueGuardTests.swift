import Foundation
import Testing

/// A test that posts to the process-wide AppKit event queue shares it with
/// every test running at the same time: a tracking loop (`NSTextField`,
/// `NSSplitView`) takes the first drag or mouse-up off the queue, whoever
/// posted it. The address-bar click test then got another test's mouse-up
/// and a partial selection ({3, 20} for {0, 23}). The suites that touch the
/// queue run one at a time as members of `LeoAppEventQueueTests`, so each
/// file that posts to it must define or extend that suite.
///
/// A deliberate exception goes in `allowlist` as `relative/path.swift` with a
/// reason.
struct LeoEventQueueGuardTests {
    static let allowlist: [String: String] = [
        "Leo/LeoIdleEventLoop.swift": "posts one applicationDefined stop event, which no mouse tracking loop matches",
    ]

    private static let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyFilePostingToTheAppEventQueueIsInTheSerializedSuite() throws {
        let sources = try Self.swiftSources()
        let offenders = Self.unserializedPosters(in: sources, allowlist: Self.allowlist.keys)
        #expect(
            offenders.isEmpty,
            "Files that call NSApp.postEvent must be inside `extension LeoAppEventQueueTests`: \(offenders.joined(separator: ", "))"
        )
    }

    @Test func theScanFlagsAnUnserializedPosterAndAcceptsTheRest() {
        let sources = [
            "a.swift": "NSApp.postEvent(event, atStart: false)",
            "b.swift": "extension LeoAppEventQueueTests {\nNSApp.postEvent(event, atStart: false)\n}",
            "c.swift": "struct LeoAppEventQueueTests {\nNSApp.postEvent(event, atStart: false)\n}",
            "d.swift": "no events here",
        ]
        #expect(Self.unserializedPosters(in: sources, allowlist: []) == ["a.swift"])
    }

    private static func swiftSources() throws -> [String: String] {
        let files = try #require(FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.path != #filePath }
            .reduce(into: [:]) { sources, url in
                sources[String(url.path.dropFirst(testsRoot.path.count + 1))] = try String(contentsOf: url, encoding: .utf8)
            }
    }

    static func unserializedPosters(in sources: [String: String], allowlist: some Collection<String>) -> [String] {
        sources.filter { path, text in
            text.contains("NSApp.postEvent(")
                && !text.contains("extension LeoAppEventQueueTests")
                && !text.contains("struct LeoAppEventQueueTests")
                && !allowlist.contains(path)
        }.keys.sorted()
    }
}
