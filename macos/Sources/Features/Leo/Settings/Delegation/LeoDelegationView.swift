import LeoKit
import SwiftUI

/// The Delegation pane: switch and active profile on top, the role × profile
/// matrix, the hide list, then the daemon's warnings and recent role dispatches
/// (read-only). A machine with no `delegation:` block gets a notice instead.
struct LeoDelegationView: View {
    @ObservedObject var model: LeoDelegationSettingsModel
    let machine: String
    var restart = LeoConfigRestartActions.none

    @State private var request: LeoDelegationRequest?

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            LeoPaneFailure(message: message) { Task { await model.load() } }
        case .loaded where !model.isConfigured:
            LeoDelegationNotConfigured(machine: machine, webLink: model.webLink)
        case .loaded:
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LeoDelegationBanners(model: model, machine: machine, restart: restart)
                header
                LeoDelegationMatrixView(model: model, request: $request)
                LeoDelegationHiddenAgents(model: model)
                LeoDelegationWarnings(warnings: model.warnings)
                LeoDelegationConsults(consults: model.recentConsults)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $request) { LeoDelegationRequestSheet(model: model, request: $0, close: { request = nil }) }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.cancelPreview() } })) {
            LeoDelegationPreviewSheet(model: model)
        }
        .alert(
            confirmationTitle, isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelConfirmation() } }),
            presenting: model.confirmation, actions: confirmationButtons, message: { Text(confirmationMessage($0)) }
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Delegation", isOn: Binding(get: { model.displayedEnabled }, set: { on in Task { await model.setEnabled(on) } }))
                    .toggleStyle(.switch).font(.headline)
                    .disabled(!model.canWrite)
                    .accessibilityIdentifier("leo.delegation.enabled")
                Text(model.displayedEnabled
                    ? "Role dispatches route through the active profile, and managed agents get the roles block."
                    : "Role dispatches fail and no roles block is injected. Template dispatches still work. Profiles and roles are kept.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 4) {
                Picker("Active profile", selection: Binding(
                    get: { model.document?.activeProfile ?? "" }, set: { profile in Task { await model.requestActivate(profile) } }
                )) {
                    ForEach(model.matrix.profiles) { Text($0.name).tag($0.name) }
                }
                .frame(width: 260).disabled(!model.canWrite)
                .accessibilityIdentifier("leo.delegation.activeProfile")
                Text("Choosing another profile shows what it changes first.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Confirmation alert

    private var confirmationTitle: String {
        switch model.confirmation {
        case .deleteRole(let name, _)?: "Delete role “\(name)”?"
        case .deleteProfile(let name, _)?: "Delete profile “\(name)”?"
        case nil: ""
        }
    }

    private func confirmationMessage(_ confirmation: LeoDelegationConfirmation) -> String {
        switch confirmation {
        case .deleteRole(let name, let profiles):
            profiles.isEmpty
                ? "“\(name)” isn’t routed by any profile. It is removed from leo.yaml on \(machine)."
                : "“\(name)” is removed from leo.yaml on \(machine), along with its routing in \(Self.list(profiles))."
        case .deleteProfile(let name, let roleCount):
            "“\(name)” and its \(roleCount == 1 ? "1 role routing" : "\(roleCount) role routings") are removed from leo.yaml on \(machine)."
        }
    }

    private static func list(_ names: [String]) -> String {
        names.count == 1 ? "profile “\(names[0])”" : "profiles " + names.map { "“\($0)”" }.joined(separator: ", ")
    }

    /// The button takes the confirmation the alert showed: SwiftUI has already
    /// closed the alert, and cleared the model's copy, by the time it runs.
    @ViewBuilder private func confirmationButtons(_ confirmation: LeoDelegationConfirmation) -> some View {
        Button("Delete", role: .destructive) { Task { await model.confirm(confirmation) } }
        Button("Cancel", role: .cancel) {}
    }
}

/// Which name sheet the pane is showing.
enum LeoDelegationRequest: Identifiable, Equatable {
    case addRole
    case renameRole(String)
    case addProfile
    case renameProfile(String)
    case duplicateProfile(String)

    var id: String {
        switch self {
        case .addRole: "addRole"
        case .renameRole(let name): "renameRole.\(name)"
        case .addProfile: "addProfile"
        case .renameProfile(let name): "renameProfile.\(name)"
        case .duplicateProfile(let name): "duplicateProfile.\(name)"
        }
    }
}

/// "Delegation isn't configured on <machine>": there is no route to create the
/// block, so this says where it is made.
struct LeoDelegationNotConfigured: View {
    let machine: String
    let webLink: URL?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Delegation isn’t configured on \(machine)").font(.headline)
            Text("Add a `delegation:` block to leo.yaml there and it appears here. Roles and profiles can be edited once it exists.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            if let webLink {
                Link("Open the web UI", destination: webLink)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
