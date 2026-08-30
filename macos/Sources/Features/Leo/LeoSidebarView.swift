import AppKit
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
                activationError: model.activationError,
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
                onSelectHost: { [weak delegate] host in delegate?.leoSelectHost(host) },
                onRetry: { [weak model] in Task { await model?.retryActivation() } },
                onDismissError: { [weak model] in model?.dismissError() })
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
    /// Non-nil when the last host retarget failed; surfaced in the error banner.
    let activationError: String?
    let hosts: [LeoHost]
    let onBoard: Set<String>
    let onAttach: (Agent) -> Void
    let onStop: (Agent) -> Void
    let onNewAgent: () -> Void
    let onNewTerminal: () -> Void
    let onSelectHost: (String) -> Void
    let onRetry: () -> Void
    let onDismissError: () -> Void

    /// Set to the agent the user wants to stop; triggers the confirmation dialog.
    @State private var agentToStop: Agent?

    /// The error to display — retarget error takes priority, else store error.
    private var displayError: String? { activationError ?? store.lastError }
    private var isRetargetError: Bool { activationError != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = displayError {
                LeoErrorBanner(
                    message: error,
                    canRetry: isRetargetError,
                    onRetry: onRetry,
                    onDismiss: onDismissError)
            }
            Divider()
            List {
                Section("Agents") {
                    if store.agents.isEmpty {
                        emptyAgentsState
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
        .confirmationDialog(
            "Stop agent \"\(agentToStop?.name ?? "")\"?",
            isPresented: Binding(
                get: { agentToStop != nil },
                set: { if !$0 { agentToStop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) {
                if let agent = agentToStop { onStop(agent) }
                agentToStop = nil
            }
            Button("Cancel", role: .cancel) { agentToStop = nil }
        } message: {
            Text("The agent's session will end.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Leo").font(.headline)
                Spacer()
                daemonStatusIndicator
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
            }
            hostPicker
        }
        .padding(8)
    }

    /// Online: filled circle in the running color. Offline: wifi.slash icon
    /// in the needs-you color.
    @ViewBuilder
    private var daemonStatusIndicator: some View {
        if store.connection == .online {
            Circle()
                .fill(LeoPalette.running)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Daemon online")
        } else {
            Image(systemName: "wifi.slash")
                .foregroundStyle(LeoPalette.needsYou)
                .font(.caption2)
                .help("Leo daemon offline")
                .accessibilityLabel("Daemon offline")
        }
    }

    /// Lets the user retarget this board to a different leo host. Always offers
    /// `localhost`; remote hosts expose their SSH target as a tooltip.
    private var hostPicker: some View {
        Menu {
            ForEach(hosts) { host in
                hostMenuButton(host: host)
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

    @ViewBuilder
    private func hostMenuButton(host: LeoHost) -> some View {
        let isActive = host.name == activeHost
        let button = Button { onSelectHost(host.name) } label: {
            if isActive {
                Label(host.name, systemImage: "checkmark")
            } else {
                Text(host.name)
            }
        }
        if let ssh = host.ssh {
            button.help(ssh)
        } else {
            button
        }
    }

    /// Empty state shown in place of the agent list. Offline gets a hint on
    /// how to start the daemon plus a retry button; online-but-empty points
    /// at the New Agent button in the footer.
    private var emptyAgentsState: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.connection == .offline {
                Text("Daemon offline").foregroundStyle(.secondary).font(.caption)
                Text("Start it with `leo service start`").foregroundStyle(.secondary).font(.caption2)
                Button("Retry") { Task { await store.refresh() } }
                    .font(.caption2)
                    .buttonStyle(.borderless)
            } else {
                Text("No agents").foregroundStyle(.secondary).font(.caption)
                Text("Use New Agent below to spawn one").foregroundStyle(.secondary).font(.caption2)
            }
        }
    }

    /// Status dot color for an agent's lifecycle.
    private func statusColor(for status: AgentStatus) -> Color {
        switch status {
        case .running: return LeoPalette.running
        case .starting: return LeoPalette.starting
        case .stopped: return LeoPalette.offline
        }
    }

    private func statusAccessibilityLabel(for status: AgentStatus) -> String {
        switch status {
        case .running: return "Running"
        case .starting: return "Starting"
        case .stopped: return "Stopped"
        }
    }

    @State private var hoveredAgentName: String?

    @ViewBuilder
    private func agentRow(_ agent: Agent) -> some View {
        let isOnBoard = onBoard.contains(agent.name)
        let row = HStack(spacing: 6) {
            Circle()
                .fill(statusColor(for: agent.status))
                .frame(width: 7, height: 7)
                .accessibilityLabel(statusAccessibilityLabel(for: agent.status))
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(.callout).lineLimit(1)
                Text(agent.repo).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isOnBoard {
                Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isOnBoard ? LeoPalette.rowSelected : (hoveredAgentName == agent.name ? LeoPalette.rowHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in hoveredAgentName = hovering ? agent.name : nil }
        .onTapGesture { onAttach(agent) }
        .contextMenu {
            Button(isOnBoard ? "Focus" : "Attach to board") { onAttach(agent) }
            if agent.status == .running {
                Button("Stop…", role: .destructive) { agentToStop = agent }
            }
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(agent.name, forType: .string)
            }
        }
        if isOnBoard {
            row.help("On this board — click to focus")
        } else {
            row
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

/// Compact error banner shown directly below the sidebar header when a daemon
/// or retarget error is present. Hidden by the parent when there is no error.
struct LeoErrorBanner: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption2)
                .padding(.top, 1)
            Text(message)
                .font(.caption2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if canRetry {
                    Button("Retry", action: onRetry)
                        .font(.caption2)
                        .buttonStyle(.borderless)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(LeoPalette.errorBanner)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
