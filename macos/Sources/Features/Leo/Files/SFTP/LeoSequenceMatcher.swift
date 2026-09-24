import Foundation

/// Finds the longest listed scalar sequence that some text starts with:
/// how `LeoTextCleaner` keeps RGI flags and ZWJ sequences whole.
protocol LeoSequenceMatcher {
    /// The length of the longest listed sequence `text` starts with (0 for
    /// none), and the steps taken to find it -- the work, so tests can
    /// bound it without a clock.
    func longestMatch(in text: ArraySlice<Unicode.Scalar>) -> (length: Int, steps: Int)
}

/// Tries every listed sequence that starts with the first scalar, longest
/// first; a step is one sequence tried.
struct LeoLinearSequenceMatcher: LeoSequenceMatcher {
    func longestMatch(in text: ArraySlice<Unicode.Scalar>) -> (length: Int, steps: Int) {
        guard let first = text.first else { return (0, 0) }
        let sequences = LeoTextCleaner.subdivisionFlags + (LeoUnicodeData.zwjSequences[first] ?? [])
        var steps = 0
        for sequence in sequences {
            steps += 1
            if text.starts(with: sequence) { return (sequence.count, steps) }
        }
        return (0, steps)
    }
}
