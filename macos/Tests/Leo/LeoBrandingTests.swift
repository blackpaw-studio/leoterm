import Foundation
import Testing

/// B-218: no user-facing string says "Ghostty". Scans the app's Swift string
/// literals and nib window titles for the product word. Identifiers, config
/// keys, comments and the lowercase CLI/config names are not user-facing and
/// don't match (`\bGhostty\b` is case-sensitive and word-bounded).
struct LeoBrandingTests {
    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Leo
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // macos
        .appendingPathComponent("Sources")

    /// Files under Sources with the given extension.
    private static func files(withExtension ext: String) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: keys)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == ext }
    }

    private static let brand = #/\bGhostty\b/#
    private static let literal = #/"(?:[^"\\]|\\.)*"/#
    private static let interpolation = #/\\\([^)]*\)/#

    /// `file:line` for each Swift line whose string literal (interpolations
    /// removed) names Ghostty. Covers single-line "…" literals and the
    /// bodies of multi-line """ blocks. Comment lines outside a block are
    /// skipped.
    private static func swiftOffenders() throws -> [String] {
        try files(withExtension: "swift").flatMap { url -> [String] in
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            var isInsideBlock = false
            var offenders: [String] = []
            for (index, line) in lines.enumerated() {
                let delimiters = line.components(separatedBy: "\"\"\"").count - 1
                let startedInsideBlock = isInsideBlock
                isInsideBlock = startedInsideBlock != (delimiters % 2 == 1)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !startedInsideBlock, trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                let text = line.replacing(interpolation, with: "")
                let hit = startedInsideBlock || delimiters > 0
                    ? text.contains(brand)
                    : line.matches(of: literal).contains {
                        String(line[$0.range]).replacing(interpolation, with: "").contains(brand)
                    }
                if hit { offenders.append("\(url.lastPathComponent):\(index + 1)") }
            }
            return offenders
        }
    }

    @Test func swiftStringLiteralsNeverSayGhostty() throws {
        let offenders = try Self.swiftOffenders()
        #expect(offenders == [])
    }

    @Test func nibWindowTitlesNeverSayGhostty() throws {
        let windowTitle = #/<window title="[^"]*\bGhostty\b/#
        let offenders = try Self.files(withExtension: "xib").filter {
            try String(contentsOf: $0, encoding: .utf8).contains(windowTitle)
        }
        #expect(offenders.map(\.lastPathComponent) == [])
    }
}
