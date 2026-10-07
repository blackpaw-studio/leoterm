import Foundation
import Testing

@testable import Ghostty

struct LeoDispatchRowPresentationTests {
    private func node(name: String? = "fixer", role: String? = "implement", status: String = "running", stalled: Bool = false, depth: Int = 0) -> LeoDispatchNode {
        LeoDispatchNode(dispatch: LeoDispatch(id: "d1", name: name, role: role, status: status, stalled: stalled), depth: depth)
    }

    @Test func titleIsTheNameThenTheRoleThenAGenericWord() {
        #expect(LeoDispatchRowPresentation(node()).title == "fixer")
        #expect(LeoDispatchRowPresentation(node(name: nil)).title == "implement")
        #expect(LeoDispatchRowPresentation(node(name: nil, role: nil)).title == "Dispatch")
    }

    @Test func statusWordsForEveryLiveStatus() {
        #expect(LeoDispatchRowPresentation(node(status: "queued")).statusText == "Queued")
        #expect(LeoDispatchRowPresentation(node(status: "running")).statusText == "Running")
        #expect(LeoDispatchRowPresentation(node(status: "idle")).statusText == "Idle")
        #expect(LeoDispatchRowPresentation(node(status: "settling")).statusText == "Settling")
        #expect(LeoDispatchRowPresentation(node(status: "brand_new")).statusText == "Brand new", "an unknown status still reads")
    }

    /// Stalled is ambient text, never a badge (principle 2).
    @Test func stalledIsPlainSecondaryText() {
        #expect(LeoDispatchRowPresentation(node(stalled: true)).statusText == "Running · Stalled")
    }

    @Test func indentGrowsWithDepth() {
        let top = LeoDispatchRowPresentation(node(depth: 0)).indent
        let nested = LeoDispatchRowPresentation(node(depth: 2)).indent
        #expect(top > 0, "a child sits inside its agent row")
        #expect(nested == top + 2 * LeoDispatchRowPresentation.indentPerLevel)
    }

    @Test func indentStopsGrowingPastTheClamp() {
        let clamped = LeoDispatchRowPresentation(node(depth: LeoDispatchRowPresentation.maxIndentDepth)).indent
        #expect(LeoDispatchRowPresentation(node(depth: 12)).indent == clamped)
    }

    @Test func voiceOverReadsTitleKindAndStatus() {
        #expect(LeoDispatchRowPresentation(node()).accessibilityLabel == "fixer, dispatch, Running")
        #expect(LeoDispatchRowPresentation(node(stalled: true, depth: 1)).accessibilityLabel == "fixer, nested dispatch, Running · Stalled")
    }
}
