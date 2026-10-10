import Foundation
import Testing

@testable import Ghostty

struct LeoDispatchRowPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(minutesAgo: Double) -> String {
        ISO8601DateFormatter().string(from: Self.now.addingTimeInterval(-minutesAgo * 60))
    }

    private func node(
        name: String? = "fixer", role: String? = "implement", status: String = "running", stalled: Bool = false,
        startedAt: String? = nil, depth: Int = 0
    ) -> LeoDispatchNode {
        LeoDispatchNode(
            dispatch: LeoDispatch(id: "d1", name: name, role: role, status: status, stalled: stalled, startedAt: startedAt), depth: depth
        )
    }

    private func presentation(_ node: LeoDispatchNode) -> LeoDispatchRowPresentation {
        LeoDispatchRowPresentation(node, now: Self.now)
    }

    // MARK: Title and chip

    @Test func titleIsTheNameThenTheRoleThenAGenericWord() {
        #expect(presentation(node()).title == "fixer")
        #expect(presentation(node(name: nil)).title == "implement")
        #expect(presentation(node(name: nil, role: nil)).title == "Dispatch")
    }

    @Test func theChipShowsTheRoleAndNamelessRowsDropTheDuplicateTitle() {
        let named = presentation(node())
        #expect(named.roleChip?.text == "implement")
        #expect(named.showsTitle)
        let nameless = presentation(node(name: nil))
        #expect(nameless.roleChip?.text == "implement")
        #expect(!nameless.showsTitle, "the chip already says the role")
        let bare = presentation(node(role: nil))
        #expect(bare.roleChip == nil)
        #expect(bare.showsTitle)
    }

    @Test func roleTintMapping() {
        let expected: [(String, LeoTint)] = [
            ("explore", .cyan), ("plan", .purple), ("implement", .pink), ("implement.hard", .pink),
            ("review", .mint), ("review.security", .mint), ("review.concurrency", .mint), ("custom", .gray)
        ]
        for (role, tint) in expected {
            #expect(LeoDispatchRowPresentation.roleTint(role) == tint, "\(role)")
        }
        #expect(presentation(node(role: "plan")).roleChip?.tint == .purple)
    }

    // MARK: Elapsed

    @Test func elapsedIsWholeMinutes() {
        let elapsed = { (seconds: TimeInterval) in LeoDispatchRowPresentation.elapsed(seconds) }
        #expect(elapsed(0) == "<1m")
        #expect(elapsed(59) == "<1m")
        #expect(elapsed(60) == "1m")
        #expect(elapsed(4 * 60 + 59) == "4m")
        #expect(elapsed(59 * 60) == "59m")
        #expect(elapsed(3600) == "1h 0m")
        #expect(elapsed(3600 + 12 * 60 + 30) == "1h 12m")
        #expect(elapsed(-30) == "<1m", "clock skew never goes negative")
    }

    // MARK: Trailing status

    @Test func runningIsABluePulsingDotWithElapsed() {
        let status = presentation(node(startedAt: iso(minutesAgo: 4))).status
        #expect(status.dot == .running)
        #expect(status.dot.tint == .blue)
        #expect(status.dot.pulses)
        #expect(status.text == "4m")
        #expect(status.textTint == nil)
    }

    @Test func queuedIsHollowGrayAndIdleSettlingAreGray() {
        let queued = presentation(node(status: "queued", startedAt: iso(minutesAgo: 0.2))).status
        #expect(queued.dot == .queued)
        #expect(queued.dot.isHollow)
        #expect(queued.dot.tint == .gray)
        #expect(queued.text == "<1m")
        for word in ["idle", "settling", "brand_new"] {
            let status = presentation(node(status: word, startedAt: iso(minutesAgo: 2))).status
            #expect(status.dot == .idle, "\(word)")
            #expect(!status.dot.pulses && !status.dot.isHollow)
            #expect(status.dot.tint == .gray)
        }
    }

    @Test func stalledIsOrangeWithElapsedInTheCopy() {
        let status = presentation(node(stalled: true, startedAt: iso(minutesAgo: 31))).status
        #expect(status.dot == .stalled)
        #expect(status.dot.tint == .orange)
        #expect(!status.dot.pulses)
        #expect(status.text == "Stalled 31m")
        #expect(status.textTint == .orange)
    }

    @Test func withoutAStartTimeTheStatusWordStandsInForElapsed() {
        #expect(presentation(node()).status.text == "Running")
        #expect(presentation(node(status: "queued")).status.text == "Queued")
        #expect(presentation(node(status: "brand_new")).status.text == "Brand new", "an unknown status still reads")
        #expect(presentation(node(stalled: true)).status.text == "Stalled")
    }

    @Test func anUnparseableStartTimeFallsBackToTheWord() {
        #expect(presentation(node(startedAt: "yesterday-ish")).status.text == "Running")
    }

    // MARK: Layout and accessibility

    @Test func indentGrowsWithDepth() {
        let top = presentation(node(depth: 0)).indent
        let nested = presentation(node(depth: 2)).indent
        #expect(top > 0, "a child sits inside its agent row")
        #expect(nested == top + 2 * LeoDispatchRowPresentation.indentPerLevel)
    }

    @Test func indentStopsGrowingPastTheClamp() {
        let clamped = presentation(node(depth: LeoDispatchRowPresentation.maxIndentDepth)).indent
        #expect(presentation(node(depth: 12)).indent == clamped)
    }

    @Test func voiceOverReadsRoleKindNameAndStatus() {
        #expect(presentation(node()).accessibilityLabel == "implement dispatch fixer, Running")
        #expect(presentation(node(depth: 1)).accessibilityLabel == "nested implement dispatch fixer, Running")
        #expect(presentation(node(name: nil, role: nil)).accessibilityLabel == "dispatch, Running")
        #expect(presentation(node(role: nil)).accessibilityLabel == "dispatch fixer, Running")
        #expect(presentation(node(name: nil)).accessibilityLabel == "implement dispatch, Running")
    }

    @Test func voiceOverSaysStalledAndTheStatusWordNotTheElapsed() {
        let stalled = presentation(node(stalled: true, startedAt: iso(minutesAgo: 31)))
        #expect(stalled.accessibilityLabel == "implement dispatch fixer, Running, stalled")
        #expect(presentation(node(status: "queued", startedAt: iso(minutesAgo: 1))).accessibilityLabel == "implement dispatch fixer, Queued")
    }
}
