import Foundation

/// One pass of `LeoSFTPServerText`'s cleaning, allowlist-shaped (D-042):
/// visible text is kept (combining marks capped per base), whitespace and
/// blank glyphs collapse to one space, private-use, noncharacter and
/// unassigned scalars become one U+FFFD, and an invisible scalar survives
/// only if it is listed here and sits where it belongs:
/// - ZWJ between two emoji, at most one in a row;
/// - ZWNJ after an Indic virama before a letter of its script, or between
///   two Arabic-script letters (D-046);
/// - U+FE0E or U+FE0F, one, right after a base it flips from its default
///   presentation (D-046), and U+FE0F in a keycap (digit, "#" or "*",
///   U+FE0F, U+20E3);
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
    /// Keycap bases, which take U+FE0F only before the enclosing keycap.
    private static let keycapBases = Set("0123456789#*".unicodeScalars)
    private static let emojiSelector: Unicode.Scalar = "\u{FE0F}"
    private static let keycap: Unicode.Scalar = "\u{20E3}"
    /// Skin tones, which sit between an emoji and its ZWJ.
    private static let emojiModifiers: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
    private static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"
    private static let zeroWidthNonJoiner: Unicode.Scalar = "\u{200C}"
    /// Arabic (Persian), which shapes with ZWNJ between letters.
    private static let arabicScripts: [ClosedRange<UInt32>] = [
        0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF,
    ]
    /// The Indic scripts, which shape with ZWNJ after a virama.
    private static let indicScripts: ClosedRange<UInt32> = 0x0900...0x0DFF
    /// Bases with a standardized emoji variation sequence: Unicode 18.0.0
    /// emoji-variation-sequences.txt (the same bases take FE0E and FE0F).
    private static let variationBases: Set<UInt32> = [
        0x23, 0x2A, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0xA9, 0xAE, 0x203C, 0x2049, 0x2122,
        0x2139, 0x2194, 0x2195, 0x2196, 0x2197, 0x2198, 0x2199, 0x21A9, 0x21AA, 0x231A, 0x231B, 0x2328, 0x23CF, 0x23E9,
        0x23EA, 0x23EB, 0x23EC, 0x23ED, 0x23EE, 0x23EF, 0x23F0, 0x23F1, 0x23F2, 0x23F3, 0x23F8, 0x23F9, 0x23FA, 0x24C2,
        0x25AA, 0x25AB, 0x25B6, 0x25C0, 0x25FB, 0x25FC, 0x25FD, 0x25FE, 0x2600, 0x2601, 0x2602, 0x2603, 0x2604, 0x260E,
        0x2611, 0x2614, 0x2615, 0x2618, 0x261D, 0x2620, 0x2622, 0x2623, 0x2626, 0x262A, 0x262E, 0x262F, 0x2638, 0x2639,
        0x263A, 0x2640, 0x2642, 0x2648, 0x2649, 0x264A, 0x264B, 0x264C, 0x264D, 0x264E, 0x264F, 0x2650, 0x2651, 0x2652,
        0x2653, 0x265F, 0x2660, 0x2663, 0x2665, 0x2666, 0x2668, 0x267B, 0x267E, 0x267F, 0x2692, 0x2693, 0x2694, 0x2695,
        0x2696, 0x2697, 0x2699, 0x269B, 0x269C, 0x26A0, 0x26A1, 0x26A7, 0x26AA, 0x26AB, 0x26B0, 0x26B1, 0x26BD, 0x26BE,
        0x26C4, 0x26C5, 0x26C8, 0x26CE, 0x26CF, 0x26D1, 0x26D3, 0x26D4, 0x26E9, 0x26EA, 0x26F0, 0x26F1, 0x26F2, 0x26F3,
        0x26F4, 0x26F5, 0x26F7, 0x26F8, 0x26F9, 0x26FA, 0x26FD, 0x2702, 0x2705, 0x2708, 0x2709, 0x270A, 0x270B, 0x270C,
        0x270D, 0x270F, 0x2712, 0x2714, 0x2716, 0x271D, 0x2721, 0x2728, 0x2733, 0x2734, 0x2744, 0x2747, 0x274C, 0x274E,
        0x2753, 0x2754, 0x2755, 0x2757, 0x2763, 0x2764, 0x2795, 0x2796, 0x2797, 0x27A1, 0x27B0, 0x27BF, 0x2934, 0x2935,
        0x2B05, 0x2B06, 0x2B07, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55, 0x3030, 0x303D, 0x3297, 0x3299, 0x1F004, 0x1F170,
        0x1F171, 0x1F17E, 0x1F17F, 0x1F202, 0x1F21A, 0x1F22F, 0x1F237, 0x1F30D, 0x1F30E, 0x1F30F, 0x1F315, 0x1F31C,
        0x1F321, 0x1F324, 0x1F325, 0x1F326, 0x1F327, 0x1F328, 0x1F329, 0x1F32A, 0x1F32B, 0x1F32C, 0x1F336, 0x1F378,
        0x1F37D, 0x1F393, 0x1F396, 0x1F397, 0x1F399, 0x1F39A, 0x1F39B, 0x1F39E, 0x1F39F, 0x1F3A7, 0x1F3AC, 0x1F3AD,
        0x1F3AE, 0x1F3C2, 0x1F3C4, 0x1F3C6, 0x1F3CA, 0x1F3CB, 0x1F3CC, 0x1F3CD, 0x1F3CE, 0x1F3D4, 0x1F3D5, 0x1F3D6,
        0x1F3D7, 0x1F3D8, 0x1F3D9, 0x1F3DA, 0x1F3DB, 0x1F3DC, 0x1F3DD, 0x1F3DE, 0x1F3DF, 0x1F3E0, 0x1F3ED, 0x1F3F3,
        0x1F3F5, 0x1F3F7, 0x1F408, 0x1F415, 0x1F41F, 0x1F426, 0x1F43F, 0x1F441, 0x1F442, 0x1F446, 0x1F447, 0x1F448,
        0x1F449, 0x1F44D, 0x1F44E, 0x1F453, 0x1F46A, 0x1F47D, 0x1F4A3, 0x1F4B0, 0x1F4B3, 0x1F4BB, 0x1F4BF, 0x1F4CB,
        0x1F4DA, 0x1F4DF, 0x1F4E4, 0x1F4E5, 0x1F4E6, 0x1F4EA, 0x1F4EB, 0x1F4EC, 0x1F4ED, 0x1F4F7, 0x1F4F9, 0x1F4FA,
        0x1F4FB, 0x1F4FD, 0x1F508, 0x1F50D, 0x1F512, 0x1F513, 0x1F549, 0x1F54A, 0x1F550, 0x1F551, 0x1F552, 0x1F553,
        0x1F554, 0x1F555, 0x1F556, 0x1F557, 0x1F558, 0x1F559, 0x1F55A, 0x1F55B, 0x1F55C, 0x1F55D, 0x1F55E, 0x1F55F,
        0x1F560, 0x1F561, 0x1F562, 0x1F563, 0x1F564, 0x1F565, 0x1F566, 0x1F567, 0x1F56F, 0x1F570, 0x1F573, 0x1F574,
        0x1F575, 0x1F576, 0x1F577, 0x1F578, 0x1F579, 0x1F587, 0x1F58A, 0x1F58B, 0x1F58C, 0x1F58D, 0x1F590, 0x1F5A5,
        0x1F5A8, 0x1F5B1, 0x1F5B2, 0x1F5BC, 0x1F5C2, 0x1F5C3, 0x1F5C4, 0x1F5D1, 0x1F5D2, 0x1F5D3, 0x1F5DC, 0x1F5DD,
        0x1F5DE, 0x1F5E1, 0x1F5E3, 0x1F5E8, 0x1F5EF, 0x1F5F3, 0x1F5FA, 0x1F610, 0x1F687, 0x1F68D, 0x1F691, 0x1F694,
        0x1F698, 0x1F6AD, 0x1F6B2, 0x1F6B9, 0x1F6BA, 0x1F6BC, 0x1F6CB, 0x1F6CD, 0x1F6CE, 0x1F6CF, 0x1F6E0, 0x1F6E1,
        0x1F6E2, 0x1F6E3, 0x1F6E4, 0x1F6E5, 0x1F6E9, 0x1F6F0, 0x1F6F3,
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
            guard couldTakeSelector, let base = output.last, Self.keepsSelector(scalar, after: base, before: next) else { return }
            appendInvisible(scalar)
        } else if scalar == Self.zeroWidthJoiner {
            guard !isSpacePending, lastBase.map(Self.isPictographic) == true, next.map(Self.isPictographic) == true else { return }
            appendInvisible(scalar)
        } else if scalar == Self.zeroWidthNonJoiner {
            guard !isSpacePending, let previous = output.last, let next, Self.letters.contains(next.properties.generalCategory),
                  Self.followsVirama(previous, next) || Self.joinsArabic(previous, lastLetter, next) else { return }
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

    /// The last scalar shown past its marks, if it is a letter.
    private var lastLetter: Unicode.Scalar? {
        output.last { !Self.marks.contains($0.properties.generalCategory) }
            .flatMap { Self.letters.contains($0.properties.generalCategory) ? $0 : nil }
    }

    /// An emoji drawn as a picture -- Swift has no Extended_Pictographic,
    /// and Emoji alone would include digits, "#" and "*".
    private static func isPictographic(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isEmoji && scalar.properties.generalCategory == .otherSymbol
    }

    /// A selector draws differently only where it flips its base's default
    /// presentation; a keycap base takes U+FE0F only inside its keycap.
    private static func keepsSelector(_ selector: Unicode.Scalar, after base: Unicode.Scalar, before next: Unicode.Scalar?) -> Bool {
        if keycapBases.contains(base) { return selector == emojiSelector && next == keycap }
        let flipsDefault = selector == emojiSelector ? !base.properties.isEmojiPresentation : base.properties.isEmojiPresentation
        return presentationSelectors.contains(selector) && variationBases.contains(base.value) && flipsDefault
    }

    private static func followsVirama(_ previous: Unicode.Scalar, _ next: Unicode.Scalar) -> Bool {
        previous.properties.canonicalCombiningClass == .virama
            && indicScripts.contains(previous.value) && indicScripts.contains(next.value)
    }

    private static func joinsArabic(_ previous: Unicode.Scalar, _ letter: Unicode.Scalar?, _ next: Unicode.Scalar) -> Bool {
        [previous, letter, next].allSatisfy { scalar in scalar.map { isArabic($0) } == true }
    }

    private static func isArabic(_ scalar: Unicode.Scalar) -> Bool {
        arabicScripts.contains { $0.contains(scalar.value) }
    }
}
