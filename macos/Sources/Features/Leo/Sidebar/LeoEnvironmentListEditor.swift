import AppKit
import SwiftUI

/// The ordered environment list editor (B-283), shared by the spawn sheet
/// and Edit Order…: drag to reorder, "+" adds a configured name (offered
/// alphabetically), ⌫ or "−" removes the selected one, ⌥⌘↑/↓ move it.
/// Names only; values never reach the app.
struct LeoEnvironmentListEditor: View {
    @Binding var list: LeoEnvironmentList
    /// The catalog's names.
    let available: [String]
    /// What an empty list means, shown in its place.
    var emptyText = "Template default"
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            List(selection: $selection) {
                ForEach(list.names, id: \.self) { name in
                    Text(name).tag(name)
                }
                .onMove { list = list.moving(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(height: 104)
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if list.names.isEmpty {
                    Text(emptyText).font(.callout).foregroundStyle(.tertiary).allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Environments, in order")
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            let addable = list.addable(from: available)
            Menu {
                ForEach(addable, id: \.self) { name in
                    Button(name) { list = list.adding(name) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(addable.isEmpty)
            .help("Add Environment")
            .accessibilityLabel("Add Environment")
            Button(action: removeSelected) { Image(systemName: "minus") }
                .disabled(selection == nil)
                .help("Remove Environment")
                .accessibilityLabel("Remove Environment")
            Spacer()
            Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(selection == nil || selection == list.names.first)
                .help("Move Up (⌥⌘↑)")
                .accessibilityLabel("Move Up")
            Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(selection == nil || selection == list.names.last)
                .help("Move Down (⌥⌘↓)")
                .accessibilityLabel("Move Down")
        }
        .buttonStyle(.borderless)
    }

    private func removeSelected() {
        guard let selection else { return }
        list = list.removing(selection)
        self.selection = nil
    }

    private func move(by offset: Int) {
        guard let selection else { return }
        list = list.moving(selection, by: offset)
    }
}

/// Edit Order… for a live agent: the same editor, prefilled with the
/// effective names. Its "Restart and Resume" button is the confirmation.
struct LeoEnvironmentsSheet: View {
    let row: LeoAgentRow
    @ObservedObject var actions: LeoAgentActions
    private let initial: LeoEnvironmentList
    @State private var list: LeoEnvironmentList
    @Environment(\.dismiss) private var dismiss

    init(row: LeoAgentRow, actions: LeoAgentActions) {
        self.row = row
        self.actions = actions
        initial = LeoEnvironmentList(row.environments?.names ?? [])
        _list = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Environments for \(row.name)").font(.headline)
                Text("Applied in this order. Changing them restarts \(row.name) and resumes its session.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LeoEnvironmentListEditor(list: $list, available: actions.environmentCatalog.catalog?.names ?? [])
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(LeoEnvironmentConfirmation(agent: row.name, names: list.names).confirmTitle) {
                    actions.setEnvironments(row, names: list.names)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(list == initial)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Presents the environment change UI for both entry points (the row's
/// context menu and the Agent menu), so they can't drift apart.
@MainActor enum LeoEnvironmentChange {
    /// Asks first (the agent restarts), then sets `names`.
    static func confirm(_ row: LeoAgentRow, names: [String], actions: LeoAgentActions, window: NSWindow? = NSApp.keyWindow) {
        let confirmation = LeoEnvironmentConfirmation(agent: row.name, names: names)
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let apply = { actions.setEnvironments(row, names: names) }
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn { apply() }
            return
        }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { apply() }
        }
    }

    /// One submenu item's action.
    static func perform(_ entry: LeoEnvironmentMenuEntry, row: LeoAgentRow, actions: LeoAgentActions, window: NSWindow? = NSApp.keyWindow) {
        switch entry {
        case .toggle(let name, _):
            confirm(row, names: LeoEnvironmentList(row.environments?.names ?? []).toggling(name).names, actions: actions, window: window)
        case .reset:
            confirm(row, names: [], actions: actions, window: window)
        case .editOrder:
            let sheet = NSHostingController(rootView: LeoEnvironmentsSheet(row: row, actions: actions))
            window?.contentViewController?.presentAsSheet(sheet)
        case .placeholder, .separator:
            break
        }
    }
}
