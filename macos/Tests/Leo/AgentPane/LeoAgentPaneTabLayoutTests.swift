import Testing

@testable import Ghostty

struct LeoAgentPaneTabLayoutTests {
    typealias Tab = LeoAgentPaneTabLayout.Tab

    /// Three tabs: titles are 40 wide, summaries add 60 more. Spacing 4,
    /// "+N" button 30 wide.
    private let tabs = [
        Tab(id: "a", titleWidth: 40, fullWidth: 100),
        Tab(id: "b", titleWidth: 40, fullWidth: 100),
        Tab(id: "c", titleWidth: 40, fullWidth: 100),
    ]

    private func fit(_ tabs: [Tab]? = nil, selected: String? = "b", width: Double) -> LeoAgentPaneTabLayout {
        LeoAgentPaneTabLayout.fit(
            tabs: tabs ?? self.tabs, selected: selected, width: width, spacing: 4, overflowWidth: 30)
    }

    private func modes(_ layout: LeoAgentPaneTabLayout) -> [String] {
        layout.entries.map { "\($0.id):\($0.presentation)" }
    }

    @Test
    func everythingFullWhenItFits() {
        // 3 × 100 + 2 × 4 = 308
        let layout = fit(width: 308)
        #expect(modes(layout) == ["a:full", "b:full", "c:full"])
        #expect(layout.overflowCount == 0)
    }

    @Test
    func othersDropToTitlesAndTheSelectedKeepsItsSummary() {
        // full 308 doesn't fit; 40 + 100 + 40 + 8 = 188 does.
        let layout = fit(width: 307)
        #expect(modes(layout) == ["a:titleOnly", "b:full", "c:titleOnly"])
        #expect(fit(width: 188).entries.map(\.presentation) == [.titleOnly, .full, .titleOnly])
    }

    @Test
    func allTitlesWhenEvenTheSelectedSummaryDoesNotFit() {
        // selected-full needs 188; titles need 3 × 40 + 8 = 128.
        let layout = fit(width: 187)
        #expect(modes(layout) == ["a:titleOnly", "b:titleOnly", "c:titleOnly"])
        #expect(fit(width: 128).overflowCount == 0)
    }

    @Test
    func extraTabsCollapseIntoOverflowWhenTitlesDoNotFit() {
        // Titles need 128. At 127 one tab goes: visible = 2 titles + gap + "+1" = 40 + 4 + 40 + 4 + 30 = 118.
        let layout = fit(selected: "a", width: 127)
        #expect(modes(layout) == ["a:titleOnly", "b:titleOnly", "c:overflow"])
        #expect(layout.overflowCount == 1)
        #expect(layout.overflowLabel == "+1")
    }

    @Test
    func theSelectedTabStaysVisibleEvenWhenItIsLast() {
        let layout = fit(selected: "c", width: 100)
        // budget: 100 - 30 - 4 = 66 → selected (40) leaves 26, nothing else fits.
        #expect(modes(layout) == ["a:overflow", "b:overflow", "c:titleOnly"])
        #expect(layout.overflowCount == 2)
        #expect(layout.overflowLabel == "+2")
    }

    @Test
    func visibleTabsKeepTheirOriginalOrderAroundTheSelected() {
        // Room for the selected and one more title: the earlier tab wins.
        let layout = fit(selected: "c", width: 40 + 4 + 40 + 4 + 30)
        #expect(modes(layout) == ["a:titleOnly", "b:overflow", "c:titleOnly"])
    }

    @Test
    func theSelectedTabIsShownEvenWhenNothingFitsAtAll() {
        let layout = fit(selected: "b", width: 10)
        #expect(modes(layout) == ["a:overflow", "b:titleOnly", "c:overflow"])
    }

    @Test
    func noSelectionFillsFromTheFront() {
        let layout = fit(selected: nil, width: 40 + 4 + 40 + 4 + 30)
        #expect(modes(layout) == ["a:titleOnly", "b:titleOnly", "c:overflow"])
    }

    @Test
    func aSelectionThatIsNotATabIsTreatedAsNone() {
        let layout = fit(selected: "ghost", width: 40 + 4 + 40 + 4 + 30)
        #expect(modes(layout) == ["a:titleOnly", "b:titleOnly", "c:overflow"])
    }

    @Test
    func aTabWithoutASummaryIsAlwaysTitleWidth() {
        let bare = [
            Tab(id: "a", titleWidth: 40, fullWidth: 40),
            Tab(id: "b", titleWidth: 40, fullWidth: 100),
        ]
        // Everything fits at 40 + 100 + 4 = 144: the summaryless tab is still a title.
        #expect(fit(bare, selected: "b", width: 144).entries.map(\.presentation) == [.titleOnly, .full])
        // One point less and the summary no longer fits: all titles.
        #expect(fit(bare, selected: "b", width: 143).entries.map(\.presentation) == [.titleOnly, .titleOnly])
    }

    @Test
    func noTabsMeansAnEmptyLayout() {
        let layout = fit([], selected: nil, width: 500)
        #expect(layout.entries.isEmpty)
        #expect(layout.overflowCount == 0)
        #expect(layout.overflowLabel == nil)
    }
}
