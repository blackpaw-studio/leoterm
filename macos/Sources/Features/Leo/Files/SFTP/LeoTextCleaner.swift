import Foundation

/// One pass of `LeoSFTPServerText`'s cleaning, allowlist-shaped (D-042):
/// visible text is kept (combining marks capped per base), whitespace and
/// blank glyphs collapse to one space, private-use, noncharacter and
/// unassigned scalars become one U+FFFD, and an invisible scalar survives
/// only if it is listed here and sits where it belongs:
/// - ZWJ between two emoji, ZWNJ between letters of Arabic or an Indic
///   script, at most one in a row;
/// - U+FE0E or U+FE0F, one, right after a base;
/// - the tags of the three RGI subdivision flags.
/// Everything else invisible is dropped.
struct LeoTextCleaner {
    /// Combining marks kept after each base scalar -- enough for Hebrew
    /// with cantillation and Indic stacks; more would pile over the lines
    /// around the text.
    static let marksPerBase = 4

    private static let invisible: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
    private static let marks: Set<Unicode.GeneralCategory> = [.nonspacingMark, .enclosingMark]
    private static let letters: Set<Unicode.GeneralCategory> = [
        .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
    ]
    /// Shown as U+FFFD: nothing a font draws, or anything it might.
    private static let replaced: Set<Unicode.GeneralCategory> = [.privateUse, .unassigned, .surrogate]
    private static let replacement: Unicode.Scalar = "\u{FFFD}"
    /// Nonspacing marks that draw nothing: the combining grapheme joiner,
    /// Khmer's inherent vowels, Mongolian's free variation selectors.
    private static let invisibleMarks: Set<Unicode.Scalar> = [
        "\u{034F}", "\u{17B4}", "\u{17B5}", "\u{180B}", "\u{180C}", "\u{180D}", "\u{180F}",
    ]
    /// Glyphs that render as nothing (the Hangul fillers, the Braille
    /// blank): treated as whitespace, so they collapse like it.
    private static let blanks: Set<Unicode.Scalar> = ["\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}", "\u{2800}"]
    /// Variation selectors can carry data invisibly (D-041): only the text
    /// and emoji presentation selectors are kept.
    private static let variationSelectors: [ClosedRange<UInt32>] = [0xFE00...0xFE0F, 0xE0100...0xE01EF]
    private static let presentationSelectors: Set<Unicode.Scalar> = ["\u{FE0E}", "\u{FE0F}"]
    /// Skin tones, which sit between an emoji and its ZWJ.
    private static let emojiModifiers: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
    private static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"
    private static let zeroWidthNonJoiner: Unicode.Scalar = "\u{200C}"
    /// Arabic (Persian) and the Indic scripts, which shape with ZWNJ.
    private static let nonJoinerScripts: [ClosedRange<UInt32>] = [
        0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x08FF, 0x0900...0x0DFF, 0xFB50...0xFDFF, 0xFE70...0xFEFF,
    ]
    /// The RGI subdivision flags (England, Scotland, Wales): the only tag
    /// sequences kept, as tags spell ASCII invisibly ("ASCII smuggling").
    private static let subdivisionFlags: [[Unicode.Scalar]] = ["gbeng", "gbsct", "gbwls"].map { code in
        ["\u{1F3F4}"] + code.unicodeScalars.compactMap { Unicode.Scalar(0xE0000 + $0.value) } + ["\u{E007F}"]
    }

    /// Characters that read as a double quote. The app quotes with “ ”, so
    /// only these could close its quote; apostrophes and single quotes stay.
    private static let doubleQuoteLookalikes: Set<Unicode.Scalar> = [
        "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{AB}", "\u{BB}", "\u{2033}", "\u{2036}",
        "\u{275D}", "\u{275E}", "\u{301D}", "\u{301E}", "\u{301F}", "\u{FF02}", "\u{2E42}",
        "\u{1F676}", "\u{1F677}", "\u{1F678}", "\u{05F4}", "\u{02BA}", "\u{3003}", "\u{02DD}",
    ]

    /// `scalars` cleaned, whitespace kept (as one space) at either end.
    /// `keepingQuotes`: the app's own words keep their curly quotes.
    static func clean(_ scalars: [Unicode.Scalar], keepingQuotes: Bool) -> String {
        var cleaner = LeoTextCleaner(keepsQuotes: keepingQuotes)
        var index = 0
        while index < scalars.count {
            if let flag = subdivisionFlags.first(where: { scalars[index...].starts(with: $0) }) {
                cleaner.appendBase(flag)
                cleaner.canTakeSelector = false
                index += flag.count
                continue
            }
            cleaner.take(scalars[index], next: scalars.indices.contains(index + 1) ? scalars[index + 1] : nil)
            index += 1
        }
        return String(cleaner.output) + (cleaner.isSpacePending ? " " : "")
    }

    private let keepsQuotes: Bool
    private var output = String.UnicodeScalarView()
    private var isSpacePending = false
    private var markCount = 0
    private var canTakeSelector = false

    private init(keepsQuotes: Bool) {
        self.keepsQuotes = keepsQuotes
    }

    /// Only a base shown just now can take a selector: anything else --
    /// kept or dropped -- in between leaves it without one.
    private mutating func take(_ scalar: Unicode.Scalar, next: Unicode.Scalar?) {
        let category = scalar.properties.generalCategory
        let couldTakeSelector = canTakeSelector
        canTakeSelector = false
        if scalar.properties.isWhitespace || Self.blanks.contains(scalar) {
            isSpacePending = true
        } else if Self.variationSelectors.contains(where: { $0.contains(scalar.value) }) {
            guard couldTakeSelector, Self.presentationSelectors.contains(scalar) else { return }
            appendInvisible(scalar)
        } else if scalar == Self.zeroWidthJoiner {
            guard !isSpacePending, lastBase.map(Self.isPictographic) == true, next.map(Self.isPictographic) == true else { return }
            appendInvisible(scalar)
        } else if scalar == Self.zeroWidthNonJoiner {
            guard !isSpacePending, output.last.map(Self.usesNonJoiner) == true,
                  let next, Self.usesNonJoiner(next), Self.letters.contains(next.properties.generalCategory) else { return }
            appendInvisible(scalar)
        } else if Self.invisible.contains(category) || Self.invisibleMarks.contains(scalar) {
            return
        } else if Self.replaced.contains(category) || scalar.properties.isNoncharacterCodePoint || scalar == Self.replacement {
            guard isSpacePending || output.last != Self.replacement else { return }
            appendBase([Self.replacement])
            canTakeSelector = false
        } else if Self.marks.contains(category) {
            guard markCount < Self.marksPerBase else { return }
            markCount += 1
            appendPendingSpace()
            output.append(scalar)
        } else {
            appendBase([keepsQuotes || !Self.doubleQuoteLookalikes.contains(scalar) ? scalar : "\""])
        }
    }

    private mutating func appendPendingSpace() {
        if isSpacePending { output.append(" ") }
        isSpacePending = false
    }

    private mutating func appendBase(_ scalars: [Unicode.Scalar]) {
        appendPendingSpace()
        output.append(contentsOf: scalars)
        markCount = 0
        canTakeSelector = true
    }

    /// Only ever right after what it joins or selects: never after a space.
    private mutating func appendInvisible(_ scalar: Unicode.Scalar) {
        output.append(scalar)
    }

    /// The last scalar shown, past any presentation selector or skin tone.
    private var lastBase: Unicode.Scalar? {
        output.last { !Self.presentationSelectors.contains($0) && !Self.emojiModifiers.contains($0.value) }
    }

    /// An emoji drawn as a picture -- Swift has no Extended_Pictographic,
    /// and Emoji alone would include digits, "#" and "*".
    private static func isPictographic(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmoji && scalar.properties.generalCategory == .otherSymbol
    }

    private static func usesNonJoiner(_ scalar: Unicode.Scalar) -> Bool {
        nonJoinerScripts.contains { $0.contains(scalar.value) }
    }
}
