import Testing

@testable import Ghostty

struct LeoDrawerOcclusionTests {
    @Test func itIsVisibleOnlyWhenMountedInAVisibleWindowOpenOnTheTerminalTab() {
        #expect(LeoDrawerOcclusion.isVisible(isMounted: true, windowVisible: true, expanded: true, selectedIsTerminal: true))
    }

    @Test(arguments: [
        (false, true, true, true), (true, false, true, true), (true, true, false, true), (true, true, true, false),
    ])
    func anyOneConditionMissingHidesIt(_ c: (Bool, Bool, Bool, Bool)) {
        #expect(!LeoDrawerOcclusion.isVisible(isMounted: c.0, windowVisible: c.1, expanded: c.2, selectedIsTerminal: c.3))
    }
}
