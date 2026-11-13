import Testing

@testable import Ghostty

/// What the three tool toggles show and do, folded from the panels' state.
struct LeoToolbarToolStateTests {
    private func state(
        hasAgent: Bool = true, browserSettingOn: Bool = true, filesOpen: Bool = false, browserFront: Bool = false,
        editorHasTabs: Bool = false, paneShown: Bool = false, paneExpanded: Bool = false
    ) -> LeoToolbarToolState {
        LeoToolbarToolState(
            hasAgent: hasAgent, browserSettingOn: browserSettingOn, filesOpen: filesOpen, browserFront: browserFront,
            editorHasTabs: editorHasTabs, paneShown: paneShown, paneExpanded: paneExpanded)
    }

    @Test func withNoAgentEveryToggleIsDisabledAndOff() {
        let none = state(hasAgent: false, filesOpen: true, browserFront: true, paneShown: true, paneExpanded: true)
        for tool in [none.files, none.browser, none.agentPane] { #expect(!tool.isEnabled && !tool.isOn) }
    }

    @Test func withAnAgentEveryToggleIsEnabled() {
        let some = state()
        for tool in [some.files, some.browser, some.agentPane] { #expect(tool.isEnabled && tool.isPresent && !tool.isOn) }
    }

    @Test func eachToggleIsOnWhileItsPanelIsOpen() {
        #expect(state(filesOpen: true).files.isOn)
        #expect(state(browserFront: true).browser.isOn)
        #expect(state(paneShown: true, paneExpanded: true).agentPane.isOn)
    }

    @Test func theAgentPaneIsOnlyOnWhileShownAndExpanded() {
        #expect(!state(paneShown: true, paneExpanded: false).agentPane.isOn)
        #expect(!state(paneShown: false, paneExpanded: true).agentPane.isOn)
    }

    @Test func aToggleFollowsOnlyItsOwnPanel() {
        let filesOnly = state(filesOpen: true)
        #expect(!filesOnly.browser.isOn && !filesOnly.agentPane.isOn)
    }

    @Test func theBrowserIsRemovedNotDisabledWhenTheSettingIsOff() {
        let off = state(browserSettingOn: false, browserFront: true)
        #expect(!off.browser.isPresent)
        #expect(off.files.isPresent && off.agentPane.isPresent)
    }

    @Test func theMenuTitlesFollowTheState() {
        #expect(state().filesMenuTitle == "Show Files")
        #expect(state(filesOpen: true).filesMenuTitle == "Hide Files")
        #expect(state().browserMenuTitle == "Show Agent Browser")
        #expect(state(browserFront: true).browserMenuTitle == "Hide Agent Browser")
        #expect(state().agentPaneMenuTitle == "Show Agent Pane")
        #expect(state(paneShown: true, paneExpanded: true).agentPaneMenuTitle == "Hide Agent Pane")
    }

    @Test func clickingFilesFlipsItBetweenOpenAndClosed() {
        #expect(state().filesStep == .open)
        #expect(state(filesOpen: true).filesStep == .close)
    }

    @Test func turningTheBrowserOnOpensIt() {
        #expect(state().browserStep == .open)
        #expect(state(editorHasTabs: true).browserStep == .open)
    }

    @Test func turningTheBrowserOffClosesItWhenTheEditorHasNoTabs() {
        #expect(state(browserFront: true).browserStep == .close)
    }

    @Test func turningTheBrowserOffShowsTheEditorWhenItHasTabs() {
        #expect(state(browserFront: true, editorHasTabs: true).browserStep == .showEditor)
    }
}
