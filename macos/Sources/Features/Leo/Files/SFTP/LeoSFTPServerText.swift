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
    /// Combining marks kept after each base scalar -- enough for Hebrew
    /// with cantillation and Indic stacks; more would pile over the lines
    /// around the text.
    static let marksPerBase = 4
    /// Tag characters kept after a black flag (U+1F3F4): a subdivision
    /// flag's code and its cancel tag.
    static let tagsPerFlag = 8
    /// Scalars examined at most: a status message can run to ~256 KiB.
    private static let scanLimit = limit * 8
    private static let invisible: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
    private static let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .enclosingMark]
    /// Characters that read as a double quote. The app quotes with “ ”, so
    /// only these could close its quote; apostrophes and single quotes stay.
    private static let doubleQuoteLookalikes: Set<Unicode.Scalar> = [
        "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{AB}", "\u{BB}", "\u{2033}", "\u{2036}",
        "\u{275D}", "\u{275E}", "\u{301D}", "\u{301E}", "\u{301F}", "\u{FF02}", "\u{2E42}",
        "\u{1F676}", "\u{1F677}", "\u{1F678}", "\u{05F4}", "\u{02BA}", "\u{3003}", "\u{02DD}",
    ]
    /// Format characters that emoji sequences and Persian and Indic text
    /// need; neither moves nor hides other text.
    private static let joiners: Set<Unicode.Scalar> = ["\u{200C}", "\u{200D}"]
    private static let blackFlag: Unicode.Scalar = "\u{1F3F4}"
    private static let tags: ClosedRange<UInt32> = 0xE0020...0xE007F
    /// First Strong Isolate and Pop Directional Isolate.
    private static let isolateStart = "\u{2068}"
    private static let isolateEnd = "\u{2069}"

    /// `text` with whitespace runs (newlines included) collapsed to one
    /// space and trimmed, control and format characters (bidi overrides and
    /// isolates, zero-widths) dropped, combining marks limited per base,
    /// double quotes and their lookalikes straightened so they can't close
    /// the app's quote, and anything past `limit` characters or
    /// `scalarLimit` scalars cut to "…". Idempotent.
    static func sanitized(_ text: String) -> String {
        let (clean, isCut) = cleaned(text, keepingQuotes: false)
        let trimmed = clean.trimmingCharacters(in: .whitespaces)
        guard isCut || trimmed.count > limit || trimmed.unicodeScalars.count > scalarLimit else { return trimmed }
        let head = String(trimmed.prefix(limit - 1)).unicodeScalars.prefix(scalarLimit - 1)
        return String(String.UnicodeScalarView(head)).trimmingCharacters(in: .whitespaces) + "…"
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

    /// The cleaning `sanitized` and `appText` share, without trimming or
    /// the length cap; `isCut` when scanning stopped at `scanLimit`.
    private static func cleaned(_ text: String, keepingQuotes: Bool) -> (text: String, isCut: Bool) {
        var result = String.UnicodeScalarView()
        var isSpacePending = false
        var markCount = 0
        var tagCount: Int?
        for (index, scalar) in text.unicodeScalars.enumerated() {
            guard index < scanLimit else {
                return (String(result) + (isSpacePending ? " " : ""), true)
            }
            if scalar.properties.isWhitespace {
                isSpacePending = true
                tagCount = nil
                continue
            }
            let isTag = tags.contains(scalar.value)
            if isTag, let count = tagCount, count < tagsPerFlag {
                tagCount = count + 1
                result.append(scalar)
                continue
            }
            let category = scalar.properties.generalCategory
            let isJoiner = joiners.contains(scalar)
            guard isJoiner || !invisible.contains(category) else { continue }
            tagCount = scalar == blackFlag ? 0 : nil
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
        return (String(result) + (isSpacePending ? " " : ""), false)
    }

    private static func straightened(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        doubleQuoteLookalikes.contains(scalar) ? "\"" : scalar
    }
}
