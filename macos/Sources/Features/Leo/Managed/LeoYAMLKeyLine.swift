import Foundation

/// The line rules the managed-config scans share (B-339's web API check,
/// B-341's viewer placement default). Each scan stays conservative: these
/// only recognise the plain shapes the daemon and people write.
enum LeoYAMLKeyLine {
    static let byteOrderMark = "\u{FEFF}"

    /// `yaml` without a leading byte order mark.
    static func droppingByteOrderMark(_ yaml: String) -> String {
        yaml.hasPrefix(byteOrderMark) ? String(yaml.dropFirst()) : yaml
    }

    static func isDocumentMarker(_ line: String) -> Bool {
        line == "---" || line.hasPrefix("--- ") || line == "..."
    }

    /// `key:`, `"key":` or `'key':` at column 0, with optional space before the colon.
    static func isKey(_ key: String, _ line: String) -> Bool {
        for candidate in [key, "\"\(key)\"", "'\(key)'"] where line.hasPrefix(candidate) {
            let rest = line.dropFirst(candidate.count).drop(while: { $0 == " " })
            guard rest.first == ":" else { continue }
            let after = rest.dropFirst()
            if after.isEmpty || after.first == " " || after.first == "\t" { return true }
        }
        return false
    }

    // MARK: block mapping entries (B-341)

    /// A block mapping entry: its key and what follows `: ` (value and any comment).
    struct KeyValue {
        let key: [Unicode.Scalar]
        let value: ArraySlice<Unicode.Scalar>
    }

    /// Scalars that can't start a plain key this scan trusts.
    private static let indicators: Set<Unicode.Scalar> = [
        "-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`",
    ]

    /// The entry on a line with its indentation removed: a plain or quoted
    /// key, optional spaces, then `:` and a space or the line's end. Nil for
    /// anything else (sequence items, complex, anchored, tagged or escaped
    /// keys, plain text), which callers treat as something they can't read.
    /// Compares scalars, never `Character`s, so no Unicode equivalence applies.
    static func keyValue(_ text: ArraySlice<Unicode.Scalar>) -> KeyValue? {
        guard let first = text.first,
              let split = first == "\"" || first == "'" ? splitQuoted(text, quote: first) : splitPlain(text),
              split.afterColon.first.map(isBlank) ?? true else { return nil }
        return KeyValue(key: split.key, value: split.afterColon.drop(while: isBlank))
    }

    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool { scalar == " " || scalar == "\t" }

    private static func splitQuoted(
        _ text: ArraySlice<Unicode.Scalar>, quote: Unicode.Scalar
    ) -> (key: [Unicode.Scalar], afterColon: ArraySlice<Unicode.Scalar>)? {
        let body = text.dropFirst()
        guard let close = body.firstIndex(of: quote) else { return nil }
        let key = Array(body[..<close])
        let rest = body[body.index(after: close)...]
        // Escapes (`\` in double quotes, `''` in single) are left to a real parser.
        guard quote == "'" ? rest.first != "'" : !key.contains("\\") else { return nil }
        let colon = rest.drop(while: { $0 == " " })
        guard colon.first == ":" else { return nil }
        return (key, colon.dropFirst())
    }

    private static func splitPlain(
        _ text: ArraySlice<Unicode.Scalar>
    ) -> (key: [Unicode.Scalar], afterColon: ArraySlice<Unicode.Scalar>)? {
        guard let first = text.first, !indicators.contains(first) else { return nil }
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            // A comment before any `: ` means the line has no key.
            if text[index] == "#", index > text.startIndex, isBlank(text[text.index(before: index)]) { return nil }
            if text[index] == ":", next == text.endIndex || isBlank(text[next]) {
                var end = index
                while end > text.startIndex, isBlank(text[text.index(before: end)]) { end = text.index(before: end) }
                return (Array(text[..<end]), text[next...])
            }
            index = next
        }
        return nil
    }
}
