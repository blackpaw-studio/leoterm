import AppKit
import SwiftUI

struct LeoSidebarView: View {
    @ObservedObject var model: LeoSidebarModel

    var body: some View {
        VStack(spacing: 10) {
            Picker("Host", selection: .constant(LeoHostID.local)) {
                Text(LeoHostID.local.displayName).tag(LeoHostID.local)
            }
            .disabled(true)
            .labelsHidden()
            .accessibilityLabel("Host")

            TextField("Search agents", text: $model.query)
                .textFieldStyle(.roundedBorder)

            content
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .background(.bar)
    }

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
                    LeoAgentRowView(row: row, isSelected: model.selection == row.id, attach: model.attachRequested)
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
        let disposition: AttachDisposition = NSEvent.modifierFlags.contains(.option) ? .newWindow : .reuseOrTab
        model.attachRequested(row, disposition)
    }
}
