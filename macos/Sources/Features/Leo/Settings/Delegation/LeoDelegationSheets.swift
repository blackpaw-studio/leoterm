import LeoKit
import SwiftUI

/// The name sheet a request asks for, wired to the model's check and write.
struct LeoDelegationRequestSheet: View {
    @ObservedObject var model: LeoDelegationSettingsModel
    let request: LeoDelegationRequest
    let close: () -> Void

    var body: some View {
        switch request {
        case .addRole:
            LeoDelegationAddRoleSheet(model: model, close: close)
        case .addProfile:
            LeoNameSheet(
                title: "New profile", confirmTitle: "Add", name: "", validate: { model.profileNameError($0) },
                submit: { name in close(); Task { await model.addProfile(name: name) } }, cancel: close
            )
        case .renameRole(let role):
            LeoNameSheet(
                title: "Rename role “\(role)”", confirmTitle: "Rename", name: role, validate: { model.roleNameError($0, excluding: role) },
                submit: { name in close(); Task { await model.renameRole(role, to: name) } }, cancel: close
            )
        case .renameProfile(let profile):
            LeoNameSheet(
                title: "Rename profile “\(profile)”", confirmTitle: "Rename", name: profile,
                validate: { model.profileNameError($0, excluding: profile) },
                submit: { name in close(); Task { await model.renameProfile(profile, to: name) } }, cancel: close
            )
        case .duplicateProfile(let profile):
            LeoNameSheet(
                title: "Duplicate profile “\(profile)”", confirmTitle: "Duplicate", name: "\(profile) copy",
                validate: { model.profileNameError($0) },
                submit: { name in close(); Task { await model.duplicateProfile(profile, as: name) } }, cancel: close
            )
        }
    }
}

/// A new role needs a template to route to; the daemon routes it that way in
/// the active profile.
struct LeoDelegationAddRoleSheet: View {
    @ObservedObject var model: LeoDelegationSettingsModel
    let close: () -> Void

    @State private var name = ""
    @State private var template = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New role").font(.headline)
            TextField("Name", text: $name).focused($isFocused).onSubmit(confirm).frame(minWidth: 300)
            Picker("Template", selection: $template) {
                ForEach(model.templates) { Text($0.name).tag($0.name) }
            }
            Text(error ?? " ").font(.caption).foregroundStyle(.red).accessibilityHidden(error == nil)
            Text("It is routed to this template in the active profile; the other profiles can route it afterwards.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Add", action: confirm).keyboardShortcut(.defaultAction).disabled(name.isEmpty || error != nil || template.isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            isFocused = true
            if template.isEmpty { template = model.templates.first?.name ?? "" }
        }
    }

    private var error: String? { name.isEmpty ? nil : model.roleNameError(name) }

    private func confirm() {
        guard error == nil, !name.isEmpty, !template.isEmpty else { return }
        let (name, template) = (name, template)
        close()
        Task { await model.addRole(name: name, template: template) }
    }
}

/// Make Active: what the switch changes, and the roles the new profile leaves
/// unrouted, before anything is written.
struct LeoDelegationPreviewSheet: View {
    @ObservedObject var model: LeoDelegationSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make “\(model.preview?.profile ?? "")” the active profile").font(.headline)
            switch model.preview {
            case .loading?, nil:
                ProgressView("Checking what changes…").frame(maxWidth: .infinity, minHeight: 80)
            case .failed(_, let message)?:
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            case .loaded(let preview)?:
                LeoDelegationPreviewBody(preview: preview, active: model.document?.activeProfile ?? "")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelPreview() }.keyboardShortcut(.cancelAction)
                Button("Make Active") { Task { await model.confirmActivate() } }
                    .keyboardShortcut(.defaultAction).disabled(!isLoaded || model.isBusy)
            }
        }
        .padding(20).frame(width: 460)
    }

    private var isLoaded: Bool {
        if case .loaded? = model.preview { true } else { false }
    }
}

/// The changes by role, then any declared roles the profile doesn't route.
struct LeoDelegationPreviewBody: View {
    let preview: LeoDelegationPreview
    let active: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if preview.changes.isEmpty {
                Text("Routing is the same as in “\(active)”. Only the active marker moves.").foregroundStyle(.secondary)
            } else {
                Text("Compared with “\(active)”:").font(.caption).foregroundStyle(.secondary)
                ForEach(preview.changes) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(change.role).font(.body.weight(.medium)).frame(width: 110, alignment: .leading).lineLimit(1)
                        Text(Self.describe(change)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !preview.missing.isEmpty {
                Label {
                    Text("Not routed by this profile: \(preview.missing.joined(separator: ", ")). Dispatches for those roles fail until it routes them.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
    }

    static func describe(_ change: LeoDelegationPreview.Change) -> String {
        switch change.kind {
        case .added: "starts routing to \(summary(change.after))"
        case .removed: "stops routing (was \(summary(change.before)))"
        case .changed: "\(summary(change.before)) → \(summary(change.after))"
        }
    }

    private static func summary(_ target: LeoDelegationTarget) -> String {
        [target.template, target.model.isEmpty ? nil : target.model, target.effort.isEmpty ? nil : target.effort]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
