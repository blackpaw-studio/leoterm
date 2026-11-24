import LeoKit
import SwiftUI

/// "Add Claude Code account": a small sheet with a machine pop-up. This Mac
/// continues to the folder panel; a connected machine lists the accounts its
/// Leo offers. Leo reads the sign-in; the plugin never sees it.
struct LeoPluginAccountSheet: View {
    @ObservedObject var model: LeoPluginAccountPickerModel
    let finish: (LeoPluginAccountChoice?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(model.kind.displayName) Account").font(.headline)
            Form {
                Picker("Machine", selection: machineBinding) {
                    ForEach(model.machines, id: \.self) { Text(Self.name($0)).tag($0) }
                }
                if model.machine != .local {
                    accountList
                }
            }
            .formStyle(.columns)
            Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button(model.machine == .local ? "Choose Folder…" : "Use Account") { finish(model.choice) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.choice == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await model.load() }
    }

    static func name(_ host: LeoHostID) -> String { host == .local ? "This Mac" : host.displayName }

    private var machineBinding: Binding<LeoHostID> {
        Binding(get: { model.machine }, set: { host in Task { await model.select(host) } })
    }

    @ViewBuilder private var accountList: some View {
        switch model.accounts {
        case .idle, .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for accounts…").foregroundStyle(.secondary) }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        case .loaded(let accounts) where accounts.isEmpty:
            Text("\(Self.name(model.machine)) has no \(model.kind.displayName) accounts.").foregroundStyle(.secondary)
        case .loaded(let accounts):
            Picker("Account", selection: $model.selectedDir) {
                Text("Choose an account").tag(String?.none)
                ForEach(accounts, id: \.dir) { account in Text("\(account.label) — \(account.dir)").tag(String?.some(account.dir)) }
            }
        }
    }

    private var caption: String {
        if model.machine == .local {
            return "Choose the \(model.kind.displayName) folder on this Mac, such as \(example). Leo reads its sign-in; the plugin never sees it."
        }
        return "\(Self.name(model.machine)) acts as the account and makes the request there. The sign-in never leaves that machine."
    }

    private var example: String { model.kind == .claudeCode ? "~/.claude" : "~/.codex" }
}
