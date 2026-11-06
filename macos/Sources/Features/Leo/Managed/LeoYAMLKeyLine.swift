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
}
