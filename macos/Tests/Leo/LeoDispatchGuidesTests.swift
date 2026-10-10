import Testing

@testable import Ghostty

/// Which tree-guide verticals each dispatch row draws, from the depth-first
/// depths of a row's dispatches.
struct LeoDispatchGuidesTests {
    @Test func aLoneChildHasOnlyItsElbow() {
        #expect(LeoDispatchGuides.continuing(depths: [0]) == [[false]])
    }

    @Test func siblingsContinueUntilTheLast() {
        #expect(LeoDispatchGuides.continuing(depths: [0, 0, 0]) == [[true], [true], [false]])
    }

    @Test func aNestedRowCarriesItsAncestorsThroughLine() {
        // a, a/b, a/c, d: a continues past its children (d follows); b has c after it.
        let guides = LeoDispatchGuides.continuing(depths: [0, 1, 1, 0])
        #expect(guides == [[true], [true, true], [true, false], [false]])
    }

    @Test func aFinishedSubtreeLeavesNoThroughLine() {
        // a, a/b, a/b/c, then nothing: every line ends.
        #expect(LeoDispatchGuides.continuing(depths: [0, 1, 2]) == [[false], [false, false], [false, false, false]])
    }
}
