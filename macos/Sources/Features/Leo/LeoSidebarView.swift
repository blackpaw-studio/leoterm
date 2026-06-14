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
                activeHost: model.activeHost,
                hosts: model.hosts,
                onBoard: Set(delegate?.leoOnBoardAgentNames() ?? []),
                onAttach: { [weak delegate] agent in delegate?.leoAddAgentCell(named: agent.name) },
                onStop: { [weak model] agent in
                    // Read the model's current store at call time so the action
                    // targets whichever host the sidebar is now following.
                    Task { await model?.store.stop(name: agent.name) }
                },
                onNewAgent: { [weak delegate] in delegate?.leoPresentSpawnSheet() },
                onNewTerminal: { [weak delegate] in delegate?.leoAddTerminalCell() },
                onSelectHost: { [weak delegate] host in delegate?.leoSelectHost(host) })
                // Load the host list when the sidebar appears; degrades to the
                // localhost-only list if `leo host list` is unavailable.
                .task { await model.refreshHosts() }
            Divider()
        }
    }
}

/// Side panel listing the daemon's agents. Actions are delivered via closures
/// so the view stays decoupled from the controller/AppKit layer.
struct LeoSidebarView: View {
    @ObservedObject var store: LeoAgentStore
    let activeHost: String
    let hosts: [LeoHost]
    let onBoard: Set<String>
    let onAttach: (Agent) -> Void
    let onStop: (Agent) -> Void
    let onNewAgent: () -> Void
    let onNewTerminal: () -> Void
    let onSelectHost: (String) -> Void

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
        // Re-run when the store instance changes (sidebar retargeted to a new
        // host) so the new host's roster refreshes immediately.
        .task(id: ObjectIdentifier(store)) { await store.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Leo").font(.headline)
                Spacer()
                Circle()
                    .fill(store.connection == .online ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            hostPicker
        }
        .padding(8)
    }

    /// Lets the user retarget this board to a different leo host. Always offers
    /// `localhost`; remote hosts show their SSH target as secondary detail.
    private var hostPicker: some View {
        Menu {
            ForEach(hosts) { host in
                Button { onSelectHost(host.name) } label: {
                    if let ssh = host.ssh {
                        Text("\(host.name) — \(ssh)")
                    } else {
                        Text(host.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: activeHost == LeoHost.localhostName ? "desktopcomputer" : "network")
                Text(activeHost).lineLimit(1)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
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
