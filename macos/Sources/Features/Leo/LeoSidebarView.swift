import SwiftUI

/// Wraps the sidebar so it observes the shared model and shows/hides itself.
/// Rendered inside TerminalView's HStack; absent in windows with no model.
struct LeoSidebarContainer: View {
    @ObservedObject var model: LeoSidebarModel
    weak var delegate: (any TerminalViewDelegate)?

    var body: some View {
        if model.isVisible {
            LeoSidebarView(
                store: model.store,
                onBoard: Set(delegate?.leoOnBoardAgentNames() ?? []),
                onAttach: { [weak delegate] agent in delegate?.leoAddAgentCell(named: agent.name) },
                onStop: { [weak model] agent in Task { await model?.store.stop(name: agent.name) } },
                onNewAgent: { [weak delegate] in delegate?.leoPresentSpawnSheet() },
                onNewTerminal: { [weak delegate] in delegate?.leoAddTerminalCell() })
            Divider()
        }
    }
}

/// Side panel listing the daemon's agents. Actions are delivered via closures
/// so the view stays decoupled from the controller/AppKit layer.
struct LeoSidebarView: View {
    @ObservedObject var store: LeoAgentStore
    let onBoard: Set<String>
    let onAttach: (Agent) -> Void
    let onStop: (Agent) -> Void
    let onNewAgent: () -> Void
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                Section("Agents") {
                    if store.agents.isEmpty {
                        Text(store.connection == .offline ? "Daemon offline" : "No agents")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(store.agents) { agent in agentRow(agent) }
                }
            }
            .listStyle(.sidebar)
            Divider()
            footer
        }
        .frame(width: 240)
        .task { await store.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Leo").font(.headline)
            Spacer()
            Circle()
                .fill(store.connection == .online ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
        .padding(8)
    }

    private func agentRow(_ agent: Agent) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(agent.status == .running ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(.callout).lineLimit(1)
                Text(agent.repo).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if onBoard.contains(agent.name) {
                Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onAttach(agent) }
        .contextMenu {
            Button("Attach to board") { onAttach(agent) }
            if agent.status == .running {
                Button("Stop agent", role: .destructive) { onStop(agent) }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Button { onNewAgent() } label: { Label("New Agent", systemImage: "plus.circle").frame(maxWidth: .infinity) }
            Button { onNewTerminal() } label: { Label("New Terminal", systemImage: "terminal").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.bordered)
        .padding(8)
    }
}
