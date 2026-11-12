import Foundation
import Testing

@testable import Ghostty

struct LeoAgentPaneStateTests {
    private let tabs = ["status", "github", "notes"]

    // MARK: Tabs

    @Test
    func tappingATabWhileCollapsedExpandsToIt() {
        let state = LeoAgentPaneState().tappingTab("github", available: tabs)
        #expect(state.isExpanded)
        #expect(state.selectedTabID == "github")
    }

    @Test
    func tappingTheSelectedTabWhileExpandedCollapsesAndKeepsTheSelection() {
        let expanded = LeoAgentPaneState().tappingTab("github", available: tabs)
        let state = expanded.tappingTab("github", available: tabs)
        #expect(!state.isExpanded)
        #expect(state.selectedTabID == "github")
    }

    @Test
    func tappingAnotherTabWhileExpandedSwitchesAndStaysExpanded() {
        let state = LeoAgentPaneState()
            .tappingTab("status", available: tabs)
            .tappingTab("notes", available: tabs)
        #expect(state.isExpanded)
        #expect(state.selectedTabID == "notes")
    }

    @Test
    func tappingTheRememberedTabWhileCollapsedExpandsAgain() {
        let state = LeoAgentPaneState()
            .tappingTab("github", available: tabs)
            .tappingTab("github", available: tabs)
            .tappingTab("github", available: tabs)
        #expect(state.isExpanded)
    }

    @Test
    func tappingAnUnknownTabIsIgnored() {
        let state = LeoAgentPaneState().tappingTab("ghost", available: tabs)
        #expect(state == LeoAgentPaneState())
    }

    // MARK: Chevron and menu toggle

    @Test
    func togglingWhileCollapsedExpandsTheRememberedTab() {
        let state = LeoAgentPaneState(selectedTabID: "github").toggled(available: tabs)
        #expect(state.isExpanded)
        #expect(state.selectedTabID == "github")
    }

    @Test
    func togglingWhileExpandedCollapsesAndKeepsTheSelection() {
        let state = LeoAgentPaneState(isExpanded: true, selectedTabID: "github").toggled(available: tabs)
        #expect(!state.isExpanded)
        #expect(state.selectedTabID == "github")
    }

    @Test
    func togglingWithNoRememberedTabExpandsTheFirst() {
        let state = LeoAgentPaneState().toggled(available: tabs)
        #expect(state.isExpanded)
        #expect(state.selectedTabID == "status")
    }

    @Test
    func togglingWhenTheRememberedTabWasHiddenFallsBackToTheFirst() {
        let state = LeoAgentPaneState(selectedTabID: "removed").toggled(available: tabs)
        #expect(state.isExpanded)
        #expect(state.selectedTabID == "status")
    }

    @Test
    func togglingWithNoTabsDoesNothing() {
        let state = LeoAgentPaneState().toggled(available: [])
        #expect(!state.isExpanded)
    }

    // MARK: Resolved selection

    @Test
    func resolvedSelectionFallsBackToTheFirstTabWithoutChangingState() {
        let state = LeoAgentPaneState(selectedTabID: "removed")
        #expect(state.resolvedSelection(available: tabs) == "status")
        #expect(state.selectedTabID == "removed")
        #expect(LeoAgentPaneState().resolvedSelection(available: []) == nil)
    }

    @Test
    func aHiddenSelectedTabThenTappedStillTogglesCorrectly() {
        // "removed" is no longer a tab; the strip shows "status" selected, so
        // tapping it while expanded must collapse, as the user sees it.
        let state = LeoAgentPaneState(isExpanded: true, selectedTabID: "removed")
            .tappingTab("status", available: tabs)
        #expect(!state.isExpanded)
        #expect(state.selectedTabID == "status")
    }

    // MARK: Height

    @Test
    func defaultHeightIs184() {
        #expect(LeoAgentPaneState().height == 184)
        #expect(LeoAgentPaneState.defaultHeight == 184)
    }

    @Test
    func settingHeightClampsToMinAndHalfTheColumn() {
        let state = LeoAgentPaneState()
        #expect(state.settingHeight(50, columnHeight: 800).height == 120)
        #expect(state.settingHeight(250, columnHeight: 800).height == 250)
        #expect(state.settingHeight(700, columnHeight: 800).height == 400)
    }

    @Test
    func tinyColumnsNeverDropBelowTheMinimum() {
        #expect(LeoAgentPaneState().settingHeight(500, columnHeight: 160).height == 120)
        #expect(LeoAgentPaneState.maxHeight(columnHeight: 160) == 120)
    }

    @Test
    func displayedHeightClampsTheRememberedHeightToTheCurrentColumn() {
        let state = LeoAgentPaneState(height: 400)
        #expect(state.displayedHeight(columnHeight: 500) == 250)
        #expect(state.displayedHeight(columnHeight: 1_000) == 400)
        #expect(state.height == 400)
    }

    @Test
    func nonFiniteHeightsFallBackToTheDefault() {
        #expect(LeoAgentPaneState(height: .nan).height == 184)
        #expect(LeoAgentPaneState().settingHeight(.infinity, columnHeight: 800).height == 184)
    }

    @Test
    func collapsedThicknessIs30() {
        #expect(LeoAgentPaneState.collapsedHeight == 30)
    }

    // MARK: Persistence

    @Test
    func emptyDefaultsLoadTheDefaultState() throws {
        let store = LeoAgentPaneStateStore(defaults: try suite())
        #expect(store.load() == LeoAgentPaneState())
    }

    @Test
    func savedStateRoundTripsThroughAFreshStoreOnTheSameSuite() throws {
        let defaults = try suite()
        let state = LeoAgentPaneState(isExpanded: true, selectedTabID: "github", height: 260)
        LeoAgentPaneStateStore(defaults: defaults).save(state)
        #expect(LeoAgentPaneStateStore(defaults: defaults).load() == state)
    }

    @Test
    func savingNoSelectionClearsAPreviousOne() throws {
        let defaults = try suite()
        let store = LeoAgentPaneStateStore(defaults: defaults)
        store.save(LeoAgentPaneState(selectedTabID: "github"))
        store.save(LeoAgentPaneState())
        #expect(store.load().selectedTabID == nil)
    }

    @Test
    func corruptStoredValuesFallBackPerField() throws {
        let defaults = try suite()
        defaults.set("yes", forKey: LeoAgentPaneStateStore.Keys.expanded)
        defaults.set(42, forKey: LeoAgentPaneStateStore.Keys.selectedTab)
        defaults.set(-5.0, forKey: LeoAgentPaneStateStore.Keys.height)
        let state = LeoAgentPaneStateStore(defaults: defaults).load()
        #expect(!state.isExpanded)
        #expect(state.selectedTabID == nil)
        #expect(state.height == 120)
    }

    @Test
    func suitesAreIsolatedFromEachOther() throws {
        let first = try suite()
        let second = try suite()
        LeoAgentPaneStateStore(defaults: first).save(LeoAgentPaneState(isExpanded: true))
        #expect(!LeoAgentPaneStateStore(defaults: second).load().isExpanded)
    }

    private func suite() throws -> UserDefaults {
        let name = "LeoAgentPaneStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
