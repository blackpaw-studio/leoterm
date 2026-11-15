import Testing

@testable import Ghostty
@testable import LeoKit

/// The pane model without a plugin system: the built-in Terminal is the only tab.
@MainActor
struct LeoAgentPaneModelTests {
    private let agent = LeoAgentPaneAgent(
        ref: LeoPluginAgentRef(machine: "localhost", name: "alfred"),
        identity: LeoAgentIdentity(host: .local, name: "alfred", workspace: "/w/alfred"))

    private func model(defaults: LeoInMemoryDefaults = LeoInMemoryDefaults()) -> (LeoAgentPaneModel, LeoBuiltInPaneSettings) {
        let settings = LeoBuiltInPaneSettings(defaults: defaults)
        return (LeoAgentPaneModel(surfaces: nil, settings: settings, store: LeoAgentPaneStateStore(defaults: defaults)), settings)
    }

    @Test func withNoPluginSystemAnAgentShowsAOneTabTerminalPane() {
        let (model, _) = model()
        model.setAgent(agent)
        #expect(model.isShown)
        #expect(model.tabs.map(\.id) == ["leo.terminal"])
        #expect(model.selectedTabID == "leo.terminal")
    }

    @Test func withNoAgentThereIsNoPane() {
        #expect(!model().0.isShown)
    }

    @Test func turningTheTerminalTabOffWithNoPluginsHidesThePane() {
        let (model, settings) = model()
        model.setAgent(agent)
        settings.setShowsTerminalTab(false)
        #expect(model.tabs.isEmpty)
        #expect(!model.isShown)
        settings.setShowsTerminalTab(true)
        #expect(model.isShown)
    }

    @Test func aSwitchStoredOffStartsWithoutTheTerminalTab() {
        let defaults = LeoInMemoryDefaults()
        LeoBuiltInPaneSettings(defaults: defaults).setShowsTerminalTab(false)
        let (model, _) = model(defaults: defaults)
        model.setAgent(agent)
        #expect(!model.isShown)
    }

    @Test func expandingMountsTheTerminalBodyByIdentity() {
        let (model, _) = model()
        model.setAgent(agent)
        model.toggle()
        #expect(model.mounts.body == .terminal(agent.identity))
        #expect(model.mounts.summaries == [.terminal(agent.identity)])
    }
}
