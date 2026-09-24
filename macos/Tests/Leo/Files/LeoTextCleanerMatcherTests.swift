import Foundation
import Testing

@testable import Ghostty

/// B-029: the cleaner keeps RGI sequences whole with work linear in the
/// text, finds exactly what the old one-sequence-at-a-time matcher found,
/// and its Unicode 18 tables agree with the running ICU.
struct LeoTextCleanerMatcherTests {
    /// Scalars `LeoSFTPServerText` examines at most.
    private static let scanLimit = LeoSFTPServerText.limit * 8
    private static let rgiSequences = LeoTextCleaner.subdivisionFlags + LeoUnicodeData.zwjSequences.values.flatMap { $0 }
    private static let longestSequence = rgiSequences.map(\.count).max() ?? 0

    private static func scalars(_ text: String) -> [Unicode.Scalar] { Array(text.unicodeScalars) }

    private static func run(_ piece: [Unicode.Scalar], filling count: Int) -> [Unicode.Scalar] {
        Array(Array(repeating: piece, count: count / piece.count + 1).joined().prefix(count))
    }

    /// 👩 starts 356 RGI sequences; trying each at every scalar made a
    /// scan-limit run cost ~570k checks.
    @Test func aRunOfWomenTakesAboutOneStepPerScalar() {
        let women = Self.run(["\u{1F469}"], filling: Self.scanLimit)

        let (text, steps) = LeoTextCleaner.cleaned(women, keepingQuotes: false)

        #expect(Self.scalars(text) == women)
        #expect(steps <= 2 * women.count, "\(steps) steps for \(women.count) scalars")
    }

    /// Every RGI sequence cut short of its last scalar, repeated: each start
    /// walks nearly a whole sequence and then fails.
    @Test func truncatedSequenceRunsTakeWorkLinearInTheText() {
        let length = 400
        let steps = Self.rgiSequences.map { sequence in
            LeoTextCleaner.cleaned(Self.run(Array(sequence.dropLast()), filling: length), keepingQuotes: false).matchSteps
        }

        let bound = length * (Self.longestSequence + 1)
        #expect(steps.allSatisfy { $0 <= bound }, "at most \(steps.max() ?? 0) steps for \(length) scalars (bound \(bound))")
    }

    /// The Unicode 18 variation bases sit next to `isEmojiPresentation`,
    /// which comes from the OS's ICU: a base it doesn't know as an emoji
    /// has no presentation to flip.
    @Test func everyVariationBaseIsAnEmojiUnderTheRunningICU() {
        let unknown = LeoTextCleaner.variationBases.sorted().filter { value in
            guard let scalar = Unicode.Scalar(value) else { return true }
            return scalar.properties.generalCategory == .unassigned || !scalar.properties.isEmoji
        }

        #expect(unknown.isEmpty, "not emoji under this ICU: \(unknown.map { String($0, radix: 16, uppercase: true) })")
    }
}

/// D-041/D-042: the matcher before B-029, kept as the reference. It tries
/// the subdivision flags, then every ZWJ sequence starting with the first
/// scalar, longest first.
struct LeoReferenceSequenceMatcher: LeoSequenceMatcher {
    func longestMatch(in text: ArraySlice<Unicode.Scalar>) -> (length: Int, steps: Int) {
        guard let first = text.first else { return (0, 0) }
        let sequences = LeoTextCleaner.subdivisionFlags + (LeoUnicodeData.zwjSequences[first] ?? [])
        let index = sequences.firstIndex { text.starts(with: $0) }
        return (index.map { sequences[$0].count } ?? 0, (index ?? sequences.count - 1) + 1)
    }
}

/// Differential: the cleaner's matcher against the reference, on every
/// RGI sequence, its truncations and near misses, and seeded mixed runs.
extension LeoTextCleanerMatcherTests {
    /// Scalars that sit in or next to RGI sequences.
    private static let alphabet: [Unicode.Scalar] = Array(Set(rgiSequences.joined())).sorted { $0.value < $1.value }
        + ["a", " ", "1", "#", "\u{FE0E}", "\u{FE0F}", "\u{20E3}", "\u{200C}", "\u{200D}", "\u{E0067}", "\u{E007F}", "\u{1F3FB}"]

    /// Each sequence whole, every prefix, one scalar dropped or swapped,
    /// and one scalar or a doubled joiner added.
    private static func nearMisses(of sequence: [Unicode.Scalar], _ random: inout LeoSplitMix) -> [[Unicode.Scalar]] {
        let prefixes: [[Unicode.Scalar]] = (1...sequence.count).map { Array(sequence.prefix($0)) }
        let dropped: [[Unicode.Scalar]] = sequence.indices.map { replacing(sequence, at: $0, with: []) }
        var swapped: [[Unicode.Scalar]] = []
        for index in sequence.indices {
            swapped.append(replacing(sequence, at: index, with: [pick(&random)]))
        }
        let extended: [[Unicode.Scalar]] = [sequence + [pick(&random)], sequence + ["\u{200D}", "\u{200D}"], ["a"] + sequence]
        return prefixes + dropped + swapped + extended
    }

    private static func replacing(_ sequence: [Unicode.Scalar], at index: Int, with scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        Array(sequence[..<index]) + scalars + Array(sequence[(index + 1)...])
    }

    private static func pick(_ random: inout LeoSplitMix) -> Unicode.Scalar {
        alphabet[Int(random.next() % UInt64(alphabet.count))]
    }

    /// Up to 12 pieces: whole sequences, prefixes, and loose scalars.
    private static func mixedRun(_ random: inout LeoSplitMix) -> [Unicode.Scalar] {
        (0...(random.next() % 12)).flatMap { _ -> [Unicode.Scalar] in
            let sequence = rgiSequences[Int(random.next() % UInt64(rgiSequences.count))]
            switch random.next() % 3 {
            case 0: return sequence
            case 1: return Array(sequence.prefix(Int(random.next() % UInt64(sequence.count)) + 1))
            default: return [pick(&random)]
            }
        }
    }

    private static let corpus: [[Unicode.Scalar]] = {
        var random = LeoSplitMix(seed: 29)
        let misses = rgiSequences.flatMap { nearMisses(of: $0, &random) }
        let runs = (0..<4000).map { _ in mixedRun(&random) }
        return misses + runs + [rgiSequences.flatMap { $0 }]
    }()

    @Test func theMatcherFindsWhatTheReferenceFoundAtEveryScalar() {
        let reference = LeoReferenceSequenceMatcher()
        let differing = Self.corpus.filter { text in
            text.indices.contains { start in
                LeoTextCleaner.sequenceMatcher.longestMatch(in: text[start...]).length != reference.longestMatch(in: text[start...]).length
            }
        }

        #expect(Self.corpus.count > 30000, "corpus of \(Self.corpus.count)")
        #expect(differing.isEmpty, "\(differing.count) of \(Self.corpus.count) differ, first: \(differing.first ?? [])")
    }

    @Test func cleaningIsByteIdenticalToTheReference() {
        let differing = Self.corpus.filter { text in
            let expected = LeoTextCleaner.cleaned(text, keepingQuotes: false, matcher: LeoReferenceSequenceMatcher()).text
            return Array(LeoTextCleaner.clean(text, keepingQuotes: false).utf8) != Array(expected.utf8)
        }

        #expect(differing.isEmpty, "\(differing.count) of \(Self.corpus.count) differ, first: \(differing.first ?? [])")
    }
}
