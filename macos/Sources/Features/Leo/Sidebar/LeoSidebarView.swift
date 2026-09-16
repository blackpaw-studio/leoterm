import AppKit
import SwiftUI

struct LeoSidebarView: View {
    @ObservedObject var model: LeoSidebarModel
    let windowID: LeoWindowID
    @ObservedObject var actions: LeoAgentActions
    @ObservedObject private var hostSelection: LeoHostSelection
    @State private var showingSpawn = false

    init(model: LeoSidebarModel, windowID: LeoWindowID, actions: LeoAgentActions) {
        self.model = model
        self.windowID = windowID
        self.actions = actions
        _hostSelection = ObservedObject(wrappedValue: actions.hostSelection)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("Agents").font(.headline); Spacer(); Button("New Agent") { showingSpawn = true } }
            Menu {
                ForEach(hostSelection.hosts) { host in
                    Button { hostSelection.select(host.hostID) } label: {
                        Text("\(host.hostID == hostSelection.selected ? "✓ " : "")\(glyph(host.state)) \(host.name)")
                    }
                }
                if let row = hostSelection.selectedRow, row.state == .error || row.state == .disconnected {
                    Divider()
                    Button("Retry") { hostSelection.retry() }
                }
            } label: {
                Text(hostSelection.selected.displayName)
            }
            .help(hostSelection.legacyTooltip ?? "Select host")
            .accessibilityLabel("Host")

            TextField("Search agents", text: $model.query)
                .textFieldStyle(.roundedBorder)

            content
            if let panelError {
                Text(panelError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .background(.bar)
        .sheet(isPresented: $showingSpawn) {
            SpawnAgentSheet(model: model, actions: actions) { row, disposition in
                model.attachRequested(row, windowID, disposition)
            }
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
                if let hint = hostSelection.sshHint, let ssh = hostSelection.selectedRow?.ssh {
                    Text(hint).font(.caption).multilineTextAlignment(.center)
                    Button("Open SSH") { model.sshRequested(ssh) }
                }
                Button("Retry") { model.retry() }
                Button("Start daemon") { model.startDaemonRequested() }
            }
        case .connected:
            if model.snapshot.rows.isEmpty {
                stateView { Text("No agents") }
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

    private func glyph(_ state: LeoHostState) -> String {
        switch state {
        case .local, .connected: "●"
        case .connecting: "◌"
        case .disconnected, .error, .unknown: "⚠"
        }
    }
}
