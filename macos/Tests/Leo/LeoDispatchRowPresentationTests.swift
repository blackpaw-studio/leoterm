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

    // MARK: Title and glyph

    @Test func titleIsTheNameThenTheRoleThenAGenericWord() {
        #expect(presentation(node()).title == "fixer")
        #expect(presentation(node(name: nil)).title == "implement")
        #expect(presentation(node(name: nil, role: nil)).title == "Dispatch")
    }

    @Test func roleGlyphMapping() {
        let expected: [(String?, String)] = [
            ("explore", "magnifyingglass"), ("plan", "list.bullet"), ("plan.hard", "list.bullet"),
            ("implement", "chevron.left.forwardslash.chevron.right"), ("implement.hard", "chevron.left.forwardslash.chevron.right"),
            ("review", "eye"), ("review.security", "eye"), ("review.concurrency", "eye"),
            ("custom", "circle.dashed"), (nil, "circle.dashed")
        ]
        for (role, glyph) in expected {
            #expect(presentation(node(role: role)).roleGlyph == glyph, "\(role ?? "nil")")
        }
    }

    @Test func theTooltipNamesTheDispatchAndItsFullRole() {
        #expect(presentation(node(name: "fixer", role: "implement.hard")).help == "fixer · implement.hard")
        #expect(presentation(node(name: nil, role: "plan")).help == "plan")
        #expect(presentation(node(name: "fixer", role: nil)).help == "fixer")
    }

    @Test func aNamelessSubRoleTitlesTheRowWithItsFullRole() {
        #expect(presentation(node(name: nil, role: "implement.hard")).title == "implement.hard")
    }

    @Test func aNamelessRowStillShowsItsTitleBesideTheGlyph() {
        #expect(presentation(node(name: nil)).title == "implement")
    }

    @Test func glyphInkShowsTheStatus() {
        #expect(presentation(node()).glyphInk == .tint(.blue))
        #expect(presentation(node(stalled: true)).glyphInk == .tint(.orange))
        for word in ["queued", "idle", "settling", "brand_new"] {
            #expect(presentation(node(status: word)).glyphInk == .tertiary, "\(word)")
        }
    }

    @Test func theTitleIsSecondaryAndATertiaryWhenQueued() {
        #expect(presentation(node()).titleInk == .secondary)
        #expect(presentation(node(stalled: true)).titleInk == .secondary)
        #expect(presentation(node(status: "queued")).titleInk == .tertiary)
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

    @Test func runningShowsElapsedInTertiaryText() {
        let status = presentation(node(startedAt: iso(minutesAgo: 4))).status
        #expect(status.text == "4m")
        #expect(status.textTint == nil)
    }

    @Test func queuedAndOtherStatusesShowElapsedToo() {
        #expect(presentation(node(status: "queued", startedAt: iso(minutesAgo: 0.2))).status.text == "<1m")
        #expect(presentation(node(status: "idle", startedAt: iso(minutesAgo: 2))).status.text == "2m")
    }

    @Test func stalledIsOrangeWithElapsedInTheCopy() {
        let status = presentation(node(stalled: true, startedAt: iso(minutesAgo: 31))).status
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

    @Test func theGlyphSitsOnTheParentsNameColumnPlusSixteenPerLevel() {
        let top = presentation(node(depth: 0)).indent
        #expect(top == LeoAgentRowMetrics.nameColumnInset, "a depth-0 child lines up with its agent's name")
        #expect(presentation(node(depth: 2)).indent == top + 2 * 16)
        #expect(LeoDispatchRowPresentation.indentPerLevel == 16)
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
