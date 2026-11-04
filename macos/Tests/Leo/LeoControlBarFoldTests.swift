import AppKit
import Testing

@testable import Ghostty

struct LeoControlBarFoldTests {
    @Test func aWideBarShowsBothVerbs() {
        let fold = LeoControlBarFold(barWidth: 800)
        #expect(fold.showsCompact && fold.showsClear)
    }

    @Test func aNarrowBarFoldsCompactBeforeClear() {
        let both = LeoControlBarFold(barWidth: 800)
        #expect(both.showsCompact && both.showsClear)
        // Walk down from wide: Clear never goes before Compact.
        var sawClearOnlyStep = false
        for width in stride(from: 800, through: 100, by: -1) {
            let fold = LeoControlBarFold(barWidth: CGFloat(width))
            #expect(!(fold.showsCompact && !fold.showsClear))
            if fold.showsClear && !fold.showsCompact { sawClearOnlyStep = true }
        }
        #expect(sawClearOnlyStep)
    }

    @Test func theNarrowestBarShowsNeither() {
        let fold = LeoControlBarFold(barWidth: 300)
        #expect(!fold.showsCompact && !fold.showsClear)
    }

    @Test func aNaNWidthFoldsBoth() {
        let fold = LeoControlBarFold(barWidth: .nan)
        #expect(!fold.showsCompact && !fold.showsClear)
    }
}
