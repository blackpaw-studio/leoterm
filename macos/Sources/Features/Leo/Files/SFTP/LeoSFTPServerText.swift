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
    private static let quotes: Set<Unicode.GeneralCategory> = [.initialPunctuation, .finalPunctuation]
    /// Double quotes and primes outside Pi/Pf.
    private static let quoteLookalikes: Set<Unicode.Scalar> = ["\u{FF02}", "\u{2033}", "\u{275D}", "\u{275E}"]
    /// Format characters that emoji sequences and Persian and Indic text
    /// need; neither moves nor hides other text.
    private static let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]

    /// `text` with whitespace runs (newlines included) collapsed to one
    /// space and trimmed, control and format characters (bidi overrides,
    /// zero-widths) dropped, combining marks limited per base, quotes and
    /// their lookalikes straightened so they can't close the app's quote,
    /// and anything past `limit` characters or `scalarLimit` scalars cut
    /// to "…".
    static func sanitized(_ text: String) -> String {
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
            result.append(straightened(scalar))
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
        quotes.contains(scalar.properties.generalCategory) || quoteLookalikes.contains(scalar) ? "\"" : scalar
    }
}
