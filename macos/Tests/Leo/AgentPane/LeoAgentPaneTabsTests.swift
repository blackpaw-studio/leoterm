import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoAgentPaneTabsTests {
    private func info(
        _ id: String, source: LeoPluginSource = .bundled, enabled: Bool = true, state: LeoPluginRunState = .running,
        pane: String? = "main", hidden: [String] = [], hasManifest: Bool = true
    ) -> LeoPluginInfo {
        let contributes = LeoPluginContributions(panes: pane.map { [LeoPluginPaneContribution(id: $0, title: "\(id) title", sfSymbol: "gauge")] } ?? [])
        return LeoPluginInfo(
            id: id, name: id, version: "1", source: source, isEnabled: enabled, state: state, approvedPermissions: .none,
            manifest: hasManifest ? LeoPluginManifest(id: id, name: id, version: "1", apiVersion: 1, main: "main.js", contributes: contributes) : nil,
            hiddenSections: [], hiddenPanes: hidden)
    }

    private let git = LeoPluginSource.git(url: "https://example.com/p.git", ref: "main", sha: "abc")

    @Test
    func aPluginWithAPaneGetsATabWithItsTitleAndSymbol() {
        let tabs = LeoAgentPaneTabs.make(from: [info("a")])
        #expect(tabs.map(\.id) == ["a"])
        #expect(tabs.first?.paneID == "main")
        #expect(tabs.first?.title == "a title")
        #expect(tabs.first?.sfSymbol == "gauge")
        #expect(tabs.first?.hasWarning == false)
    }

    @Test
    func pluginsWithoutAPaneOrManifestGetNoTab() {
        let tabs = LeoAgentPaneTabs.make(from: [info("a", pane: nil), info("b", hasManifest: false)])
        #expect(tabs.isEmpty)
    }

    @Test
    func firstPartyTabsComeFirstThenTheRestInTheOrderGiven() {
        let tabs = LeoAgentPaneTabs.make(from: [
            info("a", source: git), info("b", source: .bundled), info("c", source: .dev(path: "/tmp/c")), info("d", source: .bundled),
        ])
        #expect(tabs.map(\.id) == ["b", "d", "a", "c"])
    }

    @Test
    func aPluginTheUserTurnedOffHasNoTab() {
        #expect(LeoAgentPaneTabs.make(from: [info("a", enabled: false, state: .stoppedByUser)]).isEmpty)
    }

    @Test
    func aHiddenPaneHasNoTab() {
        #expect(LeoAgentPaneTabs.make(from: [info("a", hidden: ["main"])]).isEmpty)
    }

    @Test
    func aHiddenOtherPaneIdDoesNotHideThisOne() {
        #expect(LeoAgentPaneTabs.make(from: [info("a", hidden: ["other"])]).count == 1)
    }

    @Test(arguments: [
        LeoPluginRunState.restarting(reason: "crashed"), .disabled(reason: "crashed 3 times"), .refused("bad"),
    ])
    func aCrashedOrDisabledPluginKeepsItsTabWithAWarning(_ state: LeoPluginRunState) {
        let tabs = LeoAgentPaneTabs.make(from: [info("a", state: state)])
        #expect(tabs.count == 1)
        #expect(tabs.first?.hasWarning == true)
    }

    @Test
    func aRunningPluginHasNoWarning() {
        #expect(LeoAgentPaneTabs.make(from: [info("a", state: .running)]).first?.hasWarning == false)
    }
}
