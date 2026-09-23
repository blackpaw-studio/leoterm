import Foundation

/// Text a server sent (an SFTP status message), made safe to show inside
/// the app's own sentences: one line, nothing invisible, bounded, and
/// labelled as the server's so it can never read as the app's. File names
/// (local and remote alike) go through `sanitized` too, without the label.
enum LeoSFTPServerText {
    /// The most characters of a message shown, "…" included.
    static let limit = 200
    /// The most scalars shown, "…" included: one grapheme can hold many.
    static let scalarLimit = limit * 4
    /// Combining marks kept after each base scalar; the rest would stack
    /// over the lines around the text.
    static let marksPerBase = 2
    /// Scalars examined at most: a status message can run to ~256 KiB.
    private static let scanLimit = limit * 8
    private static let invisible: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
    private static let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .enclosingMark]
    /// Characters that read as a double quote. The app quotes with “ ”, so
    /// only these could close its quote; apostrophes and single quotes stay.
    private static let doubleQuoteLookalikes: Set<Unicode.Scalar> = [
        "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{AB}", "\u{BB}", "\u{2033}", "\u{2036}",
        "\u{275D}", "\u{275E}", "\u{301D}", "\u{301E}", "\u{301F}", "\u{FF02}",
    ]
    /// Format characters that emoji sequences and Persian and Indic text
    /// need; neither moves nor hides other text.
    private static let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

    /// `text` with whitespace runs (newlines included) collapsed to one
    /// space and trimmed, control and format characters (bidi overrides,
    /// zero-widths) dropped, combining marks limited per base, double
    /// quotes and their lookalikes straightened so they can't close the
    /// app's quote, and anything past `limit` characters or `scalarLimit` scalars cut
    /// to "…".
    static func sanitized(_ text: String) -> String {
        sanitized(text, keepingQuotes: false)
    }

    /// `sanitized`, but for a whole message the app wrote (whose names are
    /// already sanitized), shown on its own rather than quoted: its own
    /// quotes stay curly.
    static func sanitizedMessage(_ text: String) -> String {
        sanitized(text, keepingQuotes: true)
    }

    private static func sanitized(_ text: String, keepingQuotes: Bool) -> String {
        var result = String.UnicodeScalarView()
        var isSpacePending = false
        var isCut = false
        var markCount = 0
        for (index, scalar) in text.unicodeScalars.enumerated() {
            guard index < scanLimit else { isCut = true; break }
            if scalar.properties.isWhitespace {
                isSpacePending = !result.isEmpty
                continue
            }
            let category = scalar.properties.generalCategory
            let isJoiner = joiners.contains(scalar)
            guard isJoiner || !invisible.contains(category) else { continue }
            if marks.contains(category) {
                guard markCount < marksPerBase else { continue }
                markCount += 1
            } else if !isJoiner {
                markCount = 0
            }
            if isSpacePending { result.append(" ") }
            isSpacePending = false
            result.append(keepingQuotes ? scalar : straightened(scalar))
        }
        let clean = String(result)
        guard isCut || clean.count > limit || clean.unicodeScalars.count > scalarLimit else { return clean }
        let head = String(clean.prefix(limit - 1)).unicodeScalars.prefix(scalarLimit - 1)
        return String(String.UnicodeScalarView(head)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `text` (already sanitized) attributed to the server.
    static func quoted(_ text: String) -> String {
        "the server said “\(text)”"
    }

    private static func straightened(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        doubleQuoteLookalikes.contains(scalar) ? "\"" : scalar
    }
}
