import LeoKit
import SwiftUI

/// Conflict, failure, daemon warning and restart notices above the pane.
struct LeoDelegationBanners: View {
    @ObservedObject var model: LeoDelegationSettingsModel
    let machine: String
    let restart: LeoConfigRestartActions

    var body: some View {
        if model.conflict != nil || model.errorMessage != nil || model.warning != nil || model.restartPrompt != nil {
            VStack(spacing: 8) {
                if model.conflict != nil { conflictBanner }
                if let message = model.errorMessage { messageBanner(message, symbol: "exclamationmark.octagon.fill", tint: .red) }
                if let warning = model.warning { messageBanner(warning, symbol: "exclamationmark.triangle.fill", tint: .orange) }
                if let required = model.restartPrompt {
                    LeoRestartPrompt(required: required, machine: machine, actions: restart, dismiss: model.dismissRestartPrompt)
                }
            }
        }
    }

    private var conflictBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Changed on \(machine) since you opened it").font(.headline)
                Text("Reload keeps your edits over the new settings. Overwrite sends your change over what is there now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Reload") { Task { await model.reloadAfterConflict() } }
            Button("Overwrite", role: .destructive) { Task { await model.overwrite() } }
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func messageBanner(_ message: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(message).textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Dismiss", action: model.dismissError).buttonStyle(.borderless)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// The native agent types bridged claude agents may not spawn while delegation
/// is on: one entry per row, saved as a whole list.
struct LeoDelegationHiddenAgents: View {
    @ObservedObject var model: LeoDelegationSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hidden native agents").font(.headline)
            Text("While delegation is on, bridged claude agents can’t spawn these Claude Code agent types. An empty list hides none.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LeoListEditor(items: model.hiddenAgentNames, onChange: model.setHiddenAgents).frame(maxWidth: 360, alignment: .leading)
            if model.hiddenAgentsAreDefault {
                Text("Using the built-in list. Saving writes it to leo.yaml.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Revert") { model.revertHiddenAgents() }.disabled(model.hiddenAgentsEdit == nil || model.isBusy)
                Button("Save") { Task { await model.saveHiddenAgents() } }
                    .disabled(model.hiddenAgentsEdit?.isDirty != true || model.isBusy)
                if model.isBusy, model.hiddenAgentsEdit != nil { ProgressView().controlSize(.small) }
            }
        }
        .disabled(!model.isConfigured)
    }
}

/// What the daemon says is wrong with the block (a role routed to a missing
/// template, say). Read-only: fixing it is an edit to the matrix above.
struct LeoDelegationWarnings: View {
    let warnings: [String]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Warnings").font(.headline)
                ForEach(warnings, id: \.self) { warning in
                    Label { Text(warning).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

/// The last role-routed dispatches, newest first, as the web page lists them.
struct LeoDelegationConsults: View {
    let consults: [LeoDelegationConsult]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent role dispatches").font(.headline)
            if consults.isEmpty {
                Text("No role dispatches yet.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["Role", "Profile", "Template", "Model", "Effort", "Status"], id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(consults) { consult in
                        GridRow {
                            Text(consult.role).lineLimit(1)
                            Text(consult.profile.isEmpty ? "—" : consult.profile).lineLimit(1)
                            Text(consult.template).lineLimit(1)
                            Text(consult.model.isEmpty ? "inherit" : consult.model).foregroundStyle(consult.model.isEmpty ? .secondary : .primary).lineLimit(1)
                            Text(consult.effort.isEmpty ? "—" : consult.effort).lineLimit(1)
                            Text(consult.status).foregroundStyle(consult.status == "failed" ? .red : .secondary).lineLimit(1)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
