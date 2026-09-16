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
                Button { hostSelection.select(.local) } label: {
                    Text("\(hostSelection.selected == .local ? "✓ " : "")● localhost")
                }
                ForEach(hostSelection.hosts) { host in
                    Button { hostSelection.select(.remote(host.name)) } label: {
                        Text("\(hostSelection.selected == .remote(host.name) ? "✓ " : "")\(glyph(for: host.name)) \(host.name)")
                    }
                }
                if case .failed = hostSelection.state {
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
                if case .failed(_, let hint) = hostSelection.state, let hint, let ssh = hostSelection.selectedConfiguration?.sshTarget {
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

    /// Only the currently *selected* remote host has a live connection
    /// state to show (see `LeoHostSelection`); other configured hosts show a
    /// neutral glyph until they're selected.
    private func glyph(for hostName: String) -> String {
        guard hostSelection.selected == .remote(hostName) else { return "○" }
        switch hostSelection.state {
        case .connected: return "●"
        case .connecting: return "◌"
        case .failed: return "⚠"
        }
    }
}
