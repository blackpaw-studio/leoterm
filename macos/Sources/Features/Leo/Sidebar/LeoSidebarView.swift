import AppKit
import SwiftUI

struct LeoSidebarView: View {
    @ObservedObject var model: LeoSidebarModel
    let windowID: LeoWindowID
    @ObservedObject var actions: LeoAgentActions
    @State private var showingSpawn = false

    var body: some View {
        VStack(spacing: 10) {
            HStack { Text("Agents").font(.headline); Spacer(); Button("New Agent") { showingSpawn = true } }
            Picker("Host", selection: .constant(LeoHostID.local)) {
                Text(LeoHostID.local.displayName).tag(LeoHostID.local)
            }
            .disabled(true)
            .labelsHidden()
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
}
