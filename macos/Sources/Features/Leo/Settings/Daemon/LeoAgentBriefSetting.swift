import LeoKit
import SwiftUI

/// The "Agent briefs" switch above the service status. It saves as it flips;
/// a conflict or failure shows in the usual banners.
struct LeoAgentBriefSetting: View {
    static let helpText = "Agents keep a short summary of their work. Uses a few tokens when it changes."

    let model: LeoDaemonSettingsModel
    @ObservedObject var brief: LeoConfigSingletonModel
    let machine: String
    var restart = LeoConfigRestartActions.none

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LeoConfigBanners(
                machine: machine, hasConflict: brief.conflict != nil, errorMessage: brief.errorMessage, warning: brief.warning,
                restartPrompt: brief.restartPrompt, restart: restart,
                reload: { Task { await brief.reloadAfterConflict() } }, overwrite: { Task { await brief.overwrite() } },
                dismissError: brief.dismissError, dismissRestart: brief.dismissRestartPrompt
            )
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Agent briefs", isOn: isOn)
                    .toggleStyle(.switch)
                    .disabled(brief.isBusy)
                    .accessibilityIdentifier("settings.agentBriefs")
                Text(Self.helpText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(LeoSettingsMetrics.groupPadding)
        }
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { brief.draft?.value(at: LeoAgentBriefWire.enabledField) == .bool(true) },
            set: { value in Task { await model.setBriefsEnabled(value) } }
        )
    }
}
