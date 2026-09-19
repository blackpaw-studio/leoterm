import AppKit
import SwiftUI

struct LeoSidebarView: View {
    @ObservedObject var model: LeoSidebarModel
    let windowID: LeoWindowID
    @ObservedObject var actions: LeoAgentActions
    @ObservedObject private var hostSelection: LeoHostSelection
    @State private var showingSpawn = false
    @State private var hostsSheetModel: LeoHostsSheetModel?

    init(model: LeoSidebarModel, windowID: LeoWindowID, actions: LeoAgentActions) {
        self.model = model
        self.windowID = windowID
        self.actions = actions
        _hostSelection = ObservedObject(wrappedValue: actions.hostSelection)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("Agents").font(.headline); Spacer(); Button("New Agent…") { showingSpawn = true } }
            Menu {
                hostMenuItem(name: "localhost", isSelected: hostSelection.selected == .local) {
                    hostSelection.select(.local)
                }
                ForEach(hostSelection.hosts) { host in
                    hostMenuItem(name: host.name, isSelected: hostSelection.selected == .remote(host.name)) {
                        hostSelection.select(.remote(host.name))
                    }
                }
                if case .failed = hostSelection.state {
                    Divider()
                    Button("Retry") { hostSelection.retry() }
                }
                Divider()
                Button("Manage Hosts…") { hostsSheetModel = hostSelection.makeHostsSheetModel() }
            } label: {
                Text(hostSelection.selected.displayName)
            }
            .help(hostSelection.legacyTooltip ?? "Select host")
            .accessibilityLabel("Host")

            TextField("Search agents", text: $model.query)
                .textFieldStyle(.roundedBorder)

            content
            if let panelError {
                Text(panelError).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .sheet(isPresented: $showingSpawn) {
            SpawnAgentSheet(model: model, actions: actions) { row, disposition in
                model.attachRequested(row, windowID, disposition)
            }
        }
        .sheet(item: $hostsSheetModel) { sheetModel in
            LeoHostsSheet(model: sheetModel) { hostsSheetModel = nil }
        }
    }

    private var panelError: String? { model.panelError }

    @ViewBuilder private var content: some View {
        switch model.snapshot.connectivity {
        case .loading:
            stateView { ProgressView(); Text("Loading agents…") }
        case .failed(let message):
            stateView {
                Text(message).multilineTextAlignment(.center).textSelection(.enabled)
                if case .failed(_, let hint) = hostSelection.state, let hint, let ssh = hostSelection.selectedConfiguration?.sshTarget {
                    Text(hint).font(.caption).multilineTextAlignment(.center)
                    Button("Open SSH") { model.sshRequested(ssh) }
                }
                Button("Retry") { model.retry() }
                Button("Start daemon") { model.startDaemonRequested() }
            }
        case .connected:
            if model.snapshot.rows.isEmpty {
                stateView {
                    Text("No Agents").font(.headline)
                    Text("Spawn an agent to start working with it from this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Agent…") { showingSpawn = true }
                }
            } else if model.visibleRows.isEmpty {
                stateView { Text("No matches") }
            } else {
                List(model.visibleRows, selection: $model.selection) { row in
                    LeoAgentRowView(row: row, isSelected: model.selection == row.id, attach: { row, disposition in
                        model.attachRequested(row, windowID, disposition)
                    }, actions: actions, error: model.rowErrors[row.id], errorCode: model.rowErrorCodes[row.id])
                        .tag(row.id)
                }
                .listStyle(.sidebar)
                .overlay(alignment: .bottomTrailing) {
                    Button("") { attachSelected() }
                        .keyboardShortcut(.return, modifiers: [])
                        .opacity(0)
                        .disabled(model.selection == nil)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func stateView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func attachSelected() {
        guard let selection = model.selection,
              let row = model.visibleRows.first(where: { $0.id == selection }) else { return }
        LeoAttachActivation.activate(source: .keyboard, row: row) { row, disposition in
            model.attachRequested(row, windowID, disposition)
        }
    }

    /// A single host entry in the host picker menu. Selection is conveyed by
    /// the menu's own checkmark (via `Toggle`, which macOS renders as a
    /// checked menu item), and connection state by an SF Symbol + semantic
    /// color from `LeoStatusPresentation` -- never by a typed character.
    ///
    /// Only the currently *selected* remote host has a live connection state
    /// to show (see `LeoHostSelection`); other configured hosts show a
    /// neutral glyph until they're selected.
    private func hostMenuItem(name: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        let presentation = LeoStatusPresentation.hostConnection(
            isSelected: isSelected,
            state: isSelected ? hostSelection.state : nil
        )
        return Toggle(isOn: Binding(get: { isSelected }, set: { _ in select() })) {
            Label {
                Text(name)
            } icon: {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(presentation.color)
            }
        }
        .accessibilityLabel("\(name), \(presentation.accessibilityLabel)")
    }
}
