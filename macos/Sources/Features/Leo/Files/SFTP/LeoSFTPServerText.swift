import Foundation

/// Text a server sent (an SFTP status message), made safe to show inside
/// the app's own sentences: one line, nothing invisible, bounded, and
/// labelled as the server's so it can never read as the app's.
enum LeoSFTPServerText {
    /// The most characters of a message shown, "…" included.
    static let limit = 200
    /// Scalars examined at most: a status message can run to ~256 KiB.
    private static let scanLimit = limit * 8
    private static let invisible: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]

    /// `text` with whitespace runs (newlines included) collapsed to one
    /// space and trimmed, control and format characters (bidi overrides,
    /// zero-widths) dropped, curly quotes straightened so they can't close
    /// the app's quote, and anything past `limit` cut to "…".
    static func sanitized(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var isSpacePending = false
        var isCut = false
        for (index, scalar) in text.unicodeScalars.enumerated() {
            guard index < scanLimit else { isCut = true; break }
            if scalar.properties.isWhitespace {
                isSpacePending = !result.isEmpty
                continue
            }
            guard !invisible.contains(scalar.properties.generalCategory) else { continue }
            if isSpacePending { result.append(" ") }
            isSpacePending = false
            result.append(scalar == "“" || scalar == "”" ? "\"" : scalar)
        }
        let clean = String(result)
        guard isCut || clean.count > limit else { return clean }
        return String(clean.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `text` (already sanitized) attributed to the server.
    static func quoted(_ text: String) -> String {
        "the server said “\(text)”"
    }
}
