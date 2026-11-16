import LeoKit
import SwiftUI

/// Settings ▸ General: what applies to Leo on this Mac whatever the machine,
/// all stored in this Mac's defaults. App-local: it never goes through
/// `LeoSettingsPaneState`, because nothing here lives on a machine.
struct LeoGeneralSettingsView: View {
    static let tab = LeoSettingsTab.general

    @ObservedObject var statsStyle: LeoStatsStyleSetting
    @ObservedObject var agentBrowser: LeoAgentBrowserSetting
    @ObservedObject var builtIn: LeoBuiltInPaneSettings

    var body: some View {
        Form {
            Section {
                Picker("Stats style", selection: $statsStyle.style) {
                    ForEach(LeoStatsStyle.allCases, id: \.self) { Text($0.settingsTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Preview") { LeoStatsStylePreview(style: statsStyle.style) }
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Shown beside each machine in the sidebar.")
            }
            Section {
                Toggle("Agent browser", isOn: $agentBrowser.isOn)
                    .disabled(!agentBrowser.isSupported)
                Toggle("Show Terminal tab", isOn: Binding(get: { builtIn.showsTerminalTab }, set: { builtIn.setShowsTerminalTab($0) }))
            } header: {
                Text("Agents")
            } footer: {
                Text(agentsFooter)
            }
        }
        .formStyle(.grouped)
    }

    private var agentsFooter: String {
        agentBrowser.isSupported
            ? "Agent browser lets agents open and drive a browser on this Mac; turning it off closes every agent’s browser, and their cookies and logins stay."
            : "Agent browser requires macOS 14."
    }
}
