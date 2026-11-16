import LeoKit
import SwiftUI

/// Status, the actions and a live log tail, as grouped Form sections. The
/// Daemon pane shows it on its Service section.
struct LeoServiceView: View {
    @ObservedObject var model: LeoServiceSettingsModel
    let machine: String

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            LeoPaneFailure(message: message) { Task { await model.load() } }
        case .loaded:
            Form {
                LeoServiceStatusSection(status: model.status, machine: machine)
                Section {
                    LeoServiceActions(model: model)
                    if model.notice != nil || model.agentsSummary != nil || model.errorMessage != nil {
                        LeoServiceMessages(model: model)
                    }
                }
                LeoServiceLogTail(model: model)
            }
            .formStyle(.grouped)
            .leoServiceConfirmations(model, machine: machine)
        }
    }
}

extension View {
    /// The restart questions a Service model asks, as an alert. Both the Daemon
    /// pane and This Mac's overview present them.
    func leoServiceConfirmations(_ model: LeoServiceSettingsModel, machine: String) -> some View {
        modifier(LeoServiceConfirmations(model: model, machine: machine))
    }
}

private struct LeoServiceConfirmations: ViewModifier {
    @ObservedObject var model: LeoServiceSettingsModel
    let machine: String

    func body(content: Content) -> some View {
        content.alert(
            title(for: model.confirmation),
            isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelConfirmation() } }),
            presenting: model.confirmation
        ) { pending in
            // The dismiss setter above has already cleared `confirmation`: act on the one this alert showed.
            Button(buttonTitle(for: pending), role: .destructive) { Task { await model.confirm(pending) } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(message(for: pending))
        }
    }

    private func title(for confirmation: LeoServiceSettingsModel.Confirmation?) -> String {
        switch confirmation {
        case .restartDaemon?: "Restart leo on \(machine)?"
        case .restartAgents?: "Restart every agent on \(machine)?"
        case nil: ""
        }
    }

    private func buttonTitle(for confirmation: LeoServiceSettingsModel.Confirmation) -> String {
        switch confirmation {
        case .restartDaemon: "Restart Daemon"
        case .restartAgents: "Restart All Agents"
        }
    }

    private func message(for confirmation: LeoServiceSettingsModel.Confirmation) -> String {
        switch confirmation {
        case .restartDaemon:
            "leo waits for busy agents to pause, then restarts and is unreachable for a few seconds. Agents keep their tmux sessions."
        case .restartAgents(let running):
            LeoServiceText.agentsRestartMessage(running: running)
        }
    }
}

private struct LeoServiceStatusSection: View {
    let status: LeoServiceStatus?
    let machine: String

    var body: some View {
        Section {
            if let status {
                row("Version", status.version)
                row("Process ID", String(status.pid))
                if let startedAt = status.startedAt {
                    row("Started", startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                row("Agents", agentsLine(status))
                row("Config file", status.configPath, monospaced: true)
                row("Log file", status.logPath, monospaced: true)
            } else {
                Text("No status from \(machine).").foregroundStyle(.secondary)
            }
        } header: {
            Text("leo on \(machine)")
        }
    }

    private func agentsLine(_ status: LeoServiceStatus) -> String {
        let running = status.runningAgentCount
        return "\(running) running of \(status.processes.count)"
    }

    @ViewBuilder private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        if !value.isEmpty {
            LabeledContent(label) {
                Text(value)
                    .font(monospaced ? .system(.callout, design: .monospaced) : .body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct LeoServiceActions: View {
    @ObservedObject var model: LeoServiceSettingsModel

    var body: some View {
        HStack(spacing: 10) {
            Button("Restart Daemon…") { model.requestRestartDaemon() }
                .disabled(!model.canRestartDaemon)
            Button("Restart All Agents…") { model.requestRestartAgents() }
                .disabled(!model.canRestartAgents)
            Button("Reload Config") { Task { await model.reloadConfig() } }
                .disabled(model.isRestarting || model.isWorking)
            if model.isRestarting {
                ProgressView().controlSize(.small)
                Text(model.isWaitingOnAgents ? "Waiting for busy agents to pause…" : "Waiting for leo to come back…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct LeoServiceMessages: View {
    @ObservedObject var model: LeoServiceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(LeoSettingsStatus.success.color)
            }
            if let summary = model.agentsSummary {
                Label(summary, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                HStack(alignment: .firstTextBaseline) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(LeoSettingsStatus.failure.color).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button("Dismiss") { model.dismissMessages() }.buttonStyle(.link)
                }
            }
        }
        .font(.callout)
    }
}

private struct LeoServiceLogTail: View {
    @ObservedObject var model: LeoServiceSettingsModel

    var body: some View {
        Section {
            ZStack {
                LeoLogTextView(text: model.logText, label: "Daemon log", followsEnd: true)
                if model.logText.isEmpty {
                    Text(model.logError ?? "No log output yet.").foregroundStyle(.secondary)
                }
            }
            .frame(height: 240)
            if let error = model.logError, !model.logText.isEmpty {
                Text("Couldn’t refresh the log: \(error)").font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Log")
                if model.isLogPaused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(model.isLogPaused ? "Resume" : "Pause") { model.setLogPaused(!model.isLogPaused) }
                Button("Copy") { model.copyLog() }.disabled(model.logText.isEmpty)
            }
        }
    }
}
