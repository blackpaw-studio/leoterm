import Foundation

/// Text a server sent (an SFTP status message), made safe to show inside
/// the app's own sentences: one line, nothing invisible, bounded, and
/// labelled as the server's so it can never read as the app's. File names
/// (local and remote alike) go through `sanitized` too, without the label.
/// Errors are cleaned once, when rendered (`LeoFileAccessReason`).
enum LeoSFTPServerText {
    /// The most characters of a message shown, "…" included.
    static let limit = 200
    /// The most scalars shown, "…" included: one grapheme can hold many.
    static let scalarLimit = limit * 4
    /// Scalars examined at most: a status message can run to ~256 KiB.
    private static let scanLimit = limit * 8
    /// First Strong Isolate and Pop Directional Isolate.
    private static let isolateStart = "\u{2068}"
    private static let isolateEnd = "\u{2069}"

    /// `text` with whitespace runs (newlines included) collapsed to one
    /// space and trimmed, invisible scalars dropped unless allowlisted
    /// (`LeoTextCleaner`), combining marks limited per base, double quotes
    /// and their lookalikes straightened so they can't close the app's
    /// quote, and anything past `limit` characters or
    /// `scalarLimit` scalars cut to "…". Idempotent.
    static func sanitized(_ text: String) -> String {
        let (clean, isCut) = cleaned(text, keepingQuotes: false)
        let trimmed = clean.trimmingCharacters(in: .whitespaces)
        guard isCut || trimmed.count > limit || trimmed.unicodeScalars.count > scalarLimit else { return trimmed }
        return head(of: trimmed).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Whole characters, room left for "…": a cut never splits one (a
    /// flag's tags would be left behind).
    private static func head(of text: String) -> String {
        var scalarCount = 0
        let characters = text.prefix(limit - 1).prefix { character in
            scalarCount += character.unicodeScalars.count
            return scalarCount < scalarLimit
        }
        return String(characters)
    }

    /// `sanitized`, isolated (FSI … PDI) so a right-to-left name can't
    /// reorder the sentence around it. Idempotent: any isolates already in
    /// `text` are dropped first.
    static func isolated(_ text: String) -> String {
        isolateStart + sanitized(text) + isolateEnd
    }

    /// The app's own words, still made one line and visible: whitespace
    /// runs collapse to one space (kept at either end, since the words sit
    /// between others) and its own quotes stay curly.
    static func appText(_ text: String) -> String {
        cleaned(text, keepingQuotes: true).text
    }

    /// `text` attributed to the server.
    static func quoted(_ text: String) -> LeoFileAccessReason {
        "the server said “\(text)”"
    }

    /// The cleaning `sanitized` and `appText` share (`LeoTextCleaner`),
    /// without trimming or the length cap; `isCut` when scanning stopped at
    /// `scanLimit`.
    private static func cleaned(_ text: String, keepingQuotes: Bool) -> (text: String, isCut: Bool) {
        let scalars = Array(text.unicodeScalars.prefix(scanLimit))
        let isCut = text.unicodeScalars.dropFirst(scanLimit).first != nil
        return (LeoTextCleaner.clean(scalars, keepingQuotes: keepingQuotes), isCut)
    }
}
