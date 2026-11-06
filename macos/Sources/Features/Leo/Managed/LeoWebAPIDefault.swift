import Foundation

/// B-339: whether a managed `leo.yaml` still needs the loopback web API.
/// Pure and conservative: only a regular file with no top-level `web` key is
/// `.missing`; anything this scan can't be sure of is `.skip`, so a
/// user-authored config is never rewritten on a guess.
enum LeoWebAPIDefault: Equatable, Sendable {
    case missing
    case present
    case skip(reason: String)

    static func classify(yaml: String, pathKind: LeoPathKind) -> Self {
        guard pathKind == .file else { return .skip(reason: "leo.yaml isn’t a regular file") }
        var seenContent = false
        var found = false
        let text = yaml.hasPrefix("\u{FEFF}") ? String(yaml.dropFirst()) : yaml
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(rawLine)
            if isDocumentMarker(line) {
                if seenContent { return .skip(reason: "leo.yaml has more than one YAML document") }
                continue
            }
            guard let first = line.first, first != " ", first != "\t", first != "#" else { continue }
            seenContent = true
            if first == "{" || first == "[" { return .skip(reason: "leo.yaml’s top level isn’t a block mapping") }
            if first == "-" { return .skip(reason: "leo.yaml’s top level isn’t a mapping") }
            if line.hasPrefix("<<") { return .skip(reason: "leo.yaml uses a YAML merge key") }
            if isWebKey(line) { found = true }
        }
        return found ? .present : .missing
    }

    private static func isDocumentMarker(_ line: String) -> Bool {
        line == "---" || line.hasPrefix("--- ") || line == "..."
    }

    /// `web:`, `"web":` or `'web':` at column 0, with optional space before the colon.
    private static func isWebKey(_ line: String) -> Bool {
        for key in ["web", "\"web\"", "'web'"] where line.hasPrefix(key) {
            let rest = line.dropFirst(key.count).drop(while: { $0 == " " })
            guard rest.first == ":" else { continue }
            let after = rest.dropFirst()
            if after.isEmpty || after.first == " " || after.first == "\t" { return true }
        }
        return false
    }
}
