import LeoKit
import SwiftUI

/// The notices above a config form: the file changed under the draft (Reload
/// or Overwrite), a failure, a saved-but-not-reloaded warning, and a pending
/// restart. Shared by the collection and singleton panes.
struct LeoConfigBanners: View {
    let machine: String
    let hasConflict: Bool
    let errorMessage: String?
    let warning: String?
    let restartPrompt: LeoConfigRestartRequired?
    var restart = LeoConfigRestartActions.none
    let reload: () -> Void
    let overwrite: () -> Void
    let dismissError: () -> Void
    let dismissRestart: () -> Void

    var body: some View {
        if hasConflict || errorMessage != nil || warning != nil || restartPrompt != nil {
            VStack(spacing: 8) {
                if hasConflict { conflictBanner }
                if let errorMessage { messageBanner(errorMessage, symbol: "exclamationmark.octagon.fill", tint: .red) }
                if let warning { messageBanner(warning, symbol: "exclamationmark.triangle.fill", tint: .orange) }
                if let restartPrompt {
                    LeoRestartPrompt(required: restartPrompt, machine: machine, actions: restart, dismiss: dismissRestart)
                }
            }
            .padding(12)
        }
    }

    private var conflictBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Changed on \(machine) since you opened it").font(.headline)
                Text("Reload keeps your edits over the new settings. Overwrite saves your edits over theirs now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Reload", action: reload)
            Button("Overwrite", role: .destructive, action: overwrite)
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
            Button("Dismiss", action: dismissError).buttonStyle(.borderless)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// Revert and Save under a config form.
struct LeoConfigSaveBar: View {
    let isBusy: Bool
    let isDirty: Bool
    let canSave: Bool
    let revert: () -> Void
    let save: () -> Void

    var body: some View {
        HStack {
            if isBusy { ProgressView().controlSize(.small) }
            Spacer()
            Button("Revert", action: revert).disabled(!isDirty || isBusy)
            Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
        }
        .padding(12)
    }
}
