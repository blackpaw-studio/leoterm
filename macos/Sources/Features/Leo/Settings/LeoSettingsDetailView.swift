import LeoKit
import SwiftUI

/// The page for the sidebar's selection: an app page, a machine's overview,
/// or one of its panes. Also asks before a selection discards unsaved edits.
struct LeoSettingsDetailView: View {
    @ObservedObject var sidebar: LeoSettingsSidebarModel
    @ObservedObject var model: LeoMachinesSettingsModel
    @ObservedObject var target: LeoSettingsTargetModel
    @ObservedObject var statsStyle: LeoStatsStyleSetting
    @ObservedObject var agentBrowser: LeoAgentBrowserSetting
    @ObservedObject var builtInPanes: LeoBuiltInPaneSettings
    @ObservedObject var managedFeed: LeoManagedDaemonFeed
    @ObservedObject var registry: LeoMachineRegistry
    let agents: @MainActor (LeoHostID) -> [LeoAgentRow]
    let plugins: @MainActor () -> LeoPluginSystem?

    var body: some View {
        page
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert(
                "Discard unsaved changes?",
                isPresented: Binding(get: { target.pendingChange != nil }, set: { if !$0 { sidebar.cancelPending() } })
            ) {
                Button("Discard", role: .destructive) { sidebar.confirmPending() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your edits haven't been saved to the machine.")
            }
    }

    @ViewBuilder private var page: some View {
        switch sidebar.selection {
        case .general:
            LeoGeneralSettingsView(statsStyle: statsStyle, agentBrowser: agentBrowser, builtIn: builtInPanes)
        case .plugins:
            LeoPluginsSettingsView(system: plugins)
        case .machine(.local):
            LeoThisMacOverviewView(target: target, feed: managedFeed, registry: registry, agentCount: { agents(.local).count })
        case .machine(.remote):
            LeoRemoteOverviewView(model: model, target: target, registry: registry)
        case .pane(_, let pane):
            paneView(pane)
        }
    }

    @ViewBuilder private func paneView(_ pane: LeoSettingsMachinePane) -> some View {
        switch pane {
        case .templates: LeoTemplatesSettingsView(target: target)
        case .tasks: LeoTasksSettingsView(target: target)
        case .environments: LeoEnvironmentsSettingsView(target: target)
        case .delegation: LeoDelegationSettingsView(target: target)
        case .appearance: LeoAppearanceSettingsView(target: target, agents: agents)
        case .defaults: LeoDefaultsSettingsView(target: target)
        case .daemon: LeoDaemonSettingsView(target: target)
        }
    }
}
