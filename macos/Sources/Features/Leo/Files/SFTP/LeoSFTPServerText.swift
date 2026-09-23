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
    /// Glyphs that render as nothing (the Hangul fillers, the Braille
    /// blank): treated as whitespace, so they collapse like it.
    private static let blanks: Set<Unicode.Scalar> = ["\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}", "\u{2800}"]
    /// Variation selectors can carry data invisibly (D-041): only the text
    /// and emoji presentation selectors are kept, one, right after a base.
    private static let variationSelectors: [ClosedRange<UInt32>] = [0xFE00...0xFE0F, 0xE0100...0xE01EF]
    private static let presentationSelectors: Set<Unicode.Scalar> = ["\u{FE0E}", "\u{FE0F}"]
    /// The RGI subdivision flags (England, Scotland, Wales): the only tag
    /// sequences kept. Any other tag character is dropped, as tags spell
    /// ASCII invisibly ("ASCII smuggling").
    private static let subdivisionFlags: [[Unicode.Scalar]] = ["gbeng", "gbsct", "gbwls"].map { code in
        ["\u{1F3F4}"] + code.unicodeScalars.compactMap { Unicode.Scalar(0xE0000 + $0.value) } + ["\u{E007F}"]
    }
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

    /// The cleaning `sanitized` and `appText` share, without trimming or
    /// the length cap; `isCut` when scanning stopped at `scanLimit`.
    private static func cleaned(_ text: String, keepingQuotes: Bool) -> (text: String, isCut: Bool) {
        var result = String.UnicodeScalarView()
        var isSpacePending = false
        var markCount = 0
        var canTakeSelector = false
        let scalars = Array(text.unicodeScalars.prefix(scanLimit))
        let isCut = text.unicodeScalars.dropFirst(scanLimit).first != nil
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar.properties.isWhitespace || blanks.contains(scalar) {
                isSpacePending = true
                canTakeSelector = false
                continue
            }
            if variationSelectors.contains(where: { $0.contains(scalar.value) }) {
                guard canTakeSelector, presentationSelectors.contains(scalar) else { continue }
                canTakeSelector = false
                result.append(scalar)
                continue
            }
            if let flag = subdivisionFlags.first(where: { scalars[(index - 1)...].starts(with: $0) }) {
                if isSpacePending { result.append(" ") }
                isSpacePending = false
                markCount = 0
                canTakeSelector = false
                result.append(contentsOf: flag)
                index += flag.count - 1
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
            canTakeSelector = !isJoiner && !marks.contains(category)
            if isSpacePending { result.append(" ") }
            isSpacePending = false
            result.append(keepingQuotes ? scalar : straightened(scalar))
        }
        return (String(result) + (isSpacePending ? " " : ""), isCut)
    }

    private static func straightened(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        doubleQuoteLookalikes.contains(scalar) ? "\"" : scalar
    }
}
