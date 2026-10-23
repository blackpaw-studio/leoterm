import LeoKit
import SwiftUI

/// The Service tab. Its model belongs to the target (a restart started from
/// another tab's prompt is waited out there), so this view only shows it and
/// tells it when the log is on screen.
struct LeoServiceSettingsView: View {
    static let tab = LeoSettingsTab.service

    @ObservedObject var target: LeoSettingsTargetModel

    var body: some View {
        LeoSettingsPaneState(target: target, tab: Self.tab) { client in
            LeoServicePane(target: target, client: client)
        }
    }
}

private struct LeoServicePane: View {
    @ObservedObject var target: LeoSettingsTargetModel
    @ObservedObject private var model: LeoServiceSettingsModel

    init(target: LeoSettingsTargetModel, client: any LeoConfigClient) {
        self.target = target
        model = target.service(using: client)
    }

    private var isSelected: Bool { target.selectedTab == LeoServiceSettingsView.tab }

    var body: some View {
        LeoServiceView(model: model, machine: SpawnMachineOption.title(for: target.selectedHost))
            .task { await model.load() }
            .onAppear { model.setLogVisible(isSelected) }
            .onChange(of: isSelected) { model.setLogVisible($0) }
            .onDisappear { model.setLogVisible(false) }
    }
}

/// Status, the three actions, and a live log tail.
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
            VStack(alignment: .leading, spacing: 16) {
                LeoServiceStatusCard(status: model.status, machine: machine)
                LeoServiceActions(model: model)
                LeoServiceMessages(model: model)
                LeoServiceLogTail(model: model)
            }
            .padding(16)
            .alert(
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
            "leo is unreachable for a few seconds. Running agents keep their tmux sessions."
        case .restartAgents(let running):
            if let running {
                "\(running) running agent\(running == 1 ? "" : "s") will restart and lose the current turn."
            } else {
                "Every running agent will restart and lose the current turn."
            }
        }
    }
}

private struct LeoServiceStatusCard: View {
    let status: LeoServiceStatus?
    let machine: String

    var body: some View {
        GroupBox {
            if let status {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("Version", status.version)
                    row("Process ID", String(status.pid))
                    if let startedAt = status.startedAt {
                        row("Started", startedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    row("Agents", agentsLine(status))
                    row("Config file", status.configPath, monospaced: true)
                    row("Log file", status.logPath, monospaced: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No status from \(machine).").foregroundStyle(.secondary)
            }
        } label: {
            Label("leo on \(machine)", systemImage: "server.rack").font(.headline)
        }
    }

    private func agentsLine(_ status: LeoServiceStatus) -> String {
        let running = status.runningAgentCount
        return "\(running) running of \(status.processes.count)"
    }

    @ViewBuilder private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        if !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value)
                    .font(monospaced ? .system(.callout, design: .monospaced) : .body)
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
                Text("Waiting for leo to come back…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LeoServiceMessages: View {
    @ObservedObject var model: LeoServiceSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if let summary = model.agentsSummary {
                Label(summary, systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                HStack(alignment: .firstTextBaseline) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log").font(.headline)
                if model.isLogPaused { Text("Paused").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(model.isLogPaused ? "Resume" : "Pause") { model.setLogPaused(!model.isLogPaused) }
                Button("Copy") { model.copyLog() }.disabled(model.logText.isEmpty)
            }
            ZStack {
                LeoLogTextView(text: model.logText, label: "Daemon log", followsEnd: true)
                if model.logText.isEmpty {
                    Text(model.logError ?? "No log output yet.").foregroundStyle(.secondary)
                }
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 160, maxHeight: .infinity)
            if let error = model.logError, !model.logText.isEmpty {
                Text("Couldn’t refresh the log: \(error)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }
}
