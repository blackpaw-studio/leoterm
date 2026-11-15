import Testing

@testable import Ghostty

struct LeoDrawerOcclusionTests {
    @Test func itIsVisibleOnlyWhenMountedInAVisibleWindowOpenOnTheTerminalTab() {
        #expect(LeoDrawerOcclusion.isVisible(isMounted: true, windowVisible: true, expanded: true, selectedIsTerminal: true))
    }

    struct Conditions {
        var isMounted = true
        var windowVisible = true
        var expanded = true
        var selectedIsTerminal = true
    }

    @Test(arguments: [
        Conditions(isMounted: false), Conditions(windowVisible: false),
        Conditions(expanded: false), Conditions(selectedIsTerminal: false),
    ])
    func anyOneConditionMissingHidesIt(_ c: Conditions) {
        #expect(!LeoDrawerOcclusion.isVisible(
            isMounted: c.isMounted, windowVisible: c.windowVisible, expanded: c.expanded,
            selectedIsTerminal: c.selectedIsTerminal))
    }
}
