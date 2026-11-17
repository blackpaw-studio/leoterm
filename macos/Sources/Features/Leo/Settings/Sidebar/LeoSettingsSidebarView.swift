import LeoKit
import SwiftUI

/// The Settings sidebar: App pages, then the machines, the selected one
/// expanded to its panes. Selecting a row is the only way to choose what to
/// edit, so the page always says which machine it is about.
struct LeoSettingsSidebarView: View {
    @ObservedObject var model: LeoSettingsSidebarModel
    /// Observed so the status dots follow the live connections.
    @ObservedObject var registry: LeoMachineRegistry

    var body: some View {
        List(selection: Binding<LeoSettingsSidebarItem?>(get: { model.selection }, set: { if let item = $0 { model.select(item) } })) {
            Section("App") {
                Label("General", systemImage: "gearshape").tag(LeoSettingsSidebarItem.general)
                Label("Plugins", systemImage: "puzzlepiece.extension").tag(LeoSettingsSidebarItem.plugins)
            }
            Section {
                ForEach(model.rows) { row in
                    LeoSettingsMachineRow(row: row, isExpanded: model.isExpanded(row.ref)) { model.toggleDisclosure(row.ref) }
                        .tag(LeoSettingsSidebarItem.machine(row.ref))
                    if model.isExpanded(row.ref) {
                        ForEach(LeoSettingsMachinePane.allCases, id: \.self) { pane in
                            Label(pane.title, systemImage: pane.systemImage)
                                .padding(.leading, 20)
                                .tag(LeoSettingsSidebarItem.pane(row.ref, pane))
                                .disabled(!row.panesEnabled)
                                .leoSelectionDisabled(!row.panesEnabled)
                                .opacity(row.panesEnabled ? 1 : 0.5)
                                .accessibilityLabel("\(pane.title), \(row.name)")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Machines")
                    Spacer()
                    Button(action: model.addMachine) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a machine")
                        .accessibilityLabel("Add machine")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A machine row: the disclosure chevron, the machine, and its status (a dot,
/// or "Off"). The chevron expands the row without selecting it.
private struct LeoSettingsMachineRow: View {
    let row: LeoSettingsSidebarModel.MachineRow
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse \(row.name)" : "Expand \(row.name)")
            HStack(spacing: 6) {
                Label(row.name, systemImage: row.ref == .local ? "laptopcomputer" : "server.rack")
                    .lineLimit(1)
                Spacer(minLength: 4)
                if row.isOff {
                    Text("Off").font(.callout).foregroundStyle(.secondary)
                } else {
                    LeoStatusDot(status: row.status)
                }
            }
            .opacity(row.isOff ? 0.6 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
        }
    }
}

private extension View {
    /// A row the list won't select (macOS 14+; earlier systems rely on `.disabled`).
    @ViewBuilder func leoSelectionDisabled(_ isDisabled: Bool) -> some View {
        if #available(macOS 14.0, *) { selectionDisabled(isDisabled) } else { self }
    }
}
