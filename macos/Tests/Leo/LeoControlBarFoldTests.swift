import AppKit
import Testing

@testable import Ghostty

struct LeoControlBarFoldTests {
    private static func folded(at width: CGFloat) -> [Bool] {
        let fold = LeoControlBarFold(barWidth: width)
        return [fold.showsCompact, fold.showsClear, fold.showsInterrupt, fold.showsSend]
    }

    @Test func aWideBarShowsEverything() {
        #expect(Self.folded(at: 800) == [true, true, true, true])
    }

    @Test func narrowingFoldsCompactThenClearThenInterruptThenSend() {
        // Each control, once folded, stays folded as the bar narrows further,
        // and a later one never folds while an earlier one still shows.
        var previous = Self.folded(at: 800)
        var order: [Int] = []
        for width in stride(from: 800, through: 100, by: -1) {
            let now = Self.folded(at: CGFloat(width))
            for index in now.indices where previous[index] && !now[index] { order.append(index) }
            #expect(zip(previous, now).allSatisfy { $0 || !$1 })
            previous = now
        }
        #expect(order == [0, 1, 2, 3])
    }

    @Test func theDetailColumnAt480WithTheSidebarOpenKeepsPromptAndSwitchOnly() {
        #expect(Self.folded(at: 280) == [false, false, false, false])
    }

    @Test func aNaNWidthFoldsEverything() {
        #expect(Self.folded(at: .nan) == [false, false, false, false])
    }
}
