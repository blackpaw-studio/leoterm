import Foundation
import Testing

/// B-348: a fixture window that keeps AppKit's default `isReleasedWhenClosed`
/// is released a second time by ARC when a test calls `close()`, and the test
/// host can crash on CI (it blocked 0.29.6). Every `NSWindow` / `NSPanel`
/// (or subclass) a test constructs directly must switch the flag off just
/// after construction.
///
/// This scans the test sources, so a new fixture can't regress. A deliberate
/// exception goes in `allowlist` as `relative/path.swift:<trimmed line>` with
/// a reason.
struct LeoTestWindowGuardTests {
    /// How far past the construction the flag may be set.
    static let flagWindowLines = 12
    static let allowlist: [String: String] = [:]

    private static let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func everyFixtureWindowIsSafeToClose() throws {
        let sources = try Self.swiftSources()
        let offenders = Self.unsafeConstructions(in: sources, allowlist: Self.allowlist.keys)
        #expect(
            offenders.isEmpty,
            """
            Test windows must set `isReleasedWhenClosed = false` within \(Self.flagWindowLines) lines:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test func theScanFlagsAnUnsafeWindowAndAcceptsSafeOnes() {
        let unsafe = ["let w = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)", "w.title = \"x\""]
        let flagged = ["let w = NSWindow()", "w.isReleasedWhenClosed = false"]
        let helper = ["let w = makeTestWindow()"]
        let subclass = ["private final class KeyWindow: NSWindow {", "}", "let w = KeyWindow(contentRect: .zero)"]
        let sources = ["a.swift": unsafe, "b.swift": flagged, "c.swift": helper, "d.swift": subclass]
            .mapValues { $0.joined(separator: "\n") }

        let offenders = Self.unsafeConstructions(in: sources, allowlist: [])

        #expect(offenders.count == 2)
        #expect(offenders.contains { $0.hasPrefix("a.swift:1") })
        #expect(offenders.contains { $0.hasPrefix("d.swift:3") })
    }

    private static func swiftSources() throws -> [String: String] {
        let files = try #require(FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.path != #filePath } // its own samples are fixtures, not windows
            .reduce(into: [:]) { sources, url in
                sources[String(url.path.dropFirst(testsRoot.path.count + 1))] = try String(contentsOf: url, encoding: .utf8)
            }
    }

    /// `path:line: text` for each direct window construction without the flag.
    static func unsafeConstructions(in sources: [String: String], allowlist: some Collection<String>) -> [String] {
        let allLines = sources.mapValues { $0.components(separatedBy: "\n") }
        let subclasses = allLines.values.joined().compactMap(subclassName)
        let calls = (["NSWindow", "NSPanel"] + subclasses).map { "\($0)(" }
        return allLines.sorted { $0.key < $1.key }.flatMap { path, lines in
            lines.indices.compactMap { index -> String? in
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), constructs(line, calls: calls) else { return nil }
                let following = lines[index..<min(lines.count, index + flagWindowLines + 1)]
                guard !following.contains(where: { $0.contains("isReleasedWhenClosed = false") }) else { return nil }
                guard !allowlist.contains("\(path):\(line)") else { return nil }
                return "\(path):\(index + 1): \(line)"
            }
        }
    }

    /// Whether `line` calls one of `calls` (`Name(`) as a bare initializer, not
    /// as a member (`.NSWindow(`) or the tail of a longer name (`makeNSWindow(`).
    private static func constructs(_ line: String, calls: [String]) -> Bool {
        calls.contains { call in
            var searchStart = line.startIndex
            while let found = line.range(of: call, range: searchStart..<line.endIndex) {
                let before = found.lowerBound == line.startIndex ? nil : line[line.index(before: found.lowerBound)]
                if before.map({ !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) ?? true { return true }
                searchStart = found.upperBound
            }
            return false
        }
    }

    private static func subclassName(_ line: String) -> String? {
        guard line.contains("class "), line.contains("NSWindow") || line.contains("NSPanel") else { return nil }
        guard let match = line.firstMatch(of: /class\s+(\w+)\s*:\s*(?:NSWindow|NSPanel)\b/) else { return nil }
        return String(match.1)
    }
}
