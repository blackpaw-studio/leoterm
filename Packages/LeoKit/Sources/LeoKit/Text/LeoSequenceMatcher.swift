import Foundation

/// Finds the longest listed scalar sequence that some text starts with:
/// how `LeoTextCleaner` keeps RGI flags and ZWJ sequences whole.
protocol LeoSequenceMatcher {
    /// The length of the longest listed sequence `text` starts with (0 for
    /// none), and the steps taken to find it -- the work, so tests can
    /// bound it without a clock.
    func longestMatch(in text: ArraySlice<Unicode.Scalar>) -> (length: Int, steps: Int)
}

/// A prefix trie of the listed sequences, built once: a match walks one
/// node per scalar, so a step is one scalar looked up and a match takes at
/// most the longest sequence's length plus one.
struct LeoSequenceTrie: LeoSequenceMatcher {
    private struct Node {
        var children: [Unicode.Scalar: Int] = [:]
        var endsSequence = false
    }

    /// Node 0 is the root.
    private let nodes: [Node]

    init(_ sequences: [[Unicode.Scalar]]) {
        nodes = sequences.reduce(into: [Node()]) { nodes, sequence in
            let last = sequence.reduce(0) { node, scalar in
                if let child = nodes[node].children[scalar] { return child }
                nodes.append(Node())
                nodes[node].children[scalar] = nodes.count - 1
                return nodes.count - 1
            }
            nodes[last].endsSequence = last != 0
        }
    }

    func longestMatch(in text: ArraySlice<Unicode.Scalar>) -> (length: Int, steps: Int) {
        var node = 0
        var length = 0
        var steps = 0
        for (depth, scalar) in zip(1..., text) {
            steps += 1
            guard let child = nodes[node].children[scalar] else { break }
            node = child
            if nodes[node].endsSequence { length = depth }
        }
        return (length, steps)
    }
}
