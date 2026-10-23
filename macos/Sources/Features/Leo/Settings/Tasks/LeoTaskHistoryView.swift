import LeoKit
import SwiftUI

/// A task's recent runs, newest first, and the selected run's log. Read-only.
struct LeoTaskHistoryView: View {
    @ObservedObject var model: LeoTasksSettingsModel

    var body: some View {
        switch model.history {
        case .idle, .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            LeoPaneFailure(message: message) { Task { await model.reloadHistory() } }
        case .loaded(let runs):
            if runs.isEmpty {
                VStack(spacing: 8) {
                    Text("No runs yet.").foregroundStyle(.secondary)
                    Button("Refresh") { Task { await model.reloadHistory() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VSplitView {
                    runList(runs).frame(minHeight: 110, idealHeight: 150, maxHeight: 240)
                    logPane.frame(minHeight: 160)
                }
            }
        }
    }

    private func runList(_ runs: [LeoTaskRun]) -> some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedRunID }, set: { id in if let id { Task { await model.selectRun(id) } } })) {
                ForEach(runs) { run in
                    LeoTaskRunRow(run: run).tag(run.id)
                }
            }
            .accessibilityLabel("Runs")
            Divider()
            HStack {
                Text("Last \(runs.count) run\(runs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await model.reloadHistory() } }.buttonStyle(.borderless)
            }
            .padding(6)
        }
    }

    @ViewBuilder private var logPane: some View {
        switch model.log {
        case .idle:
            Text(model.selectedRunID == nil ? "Select a run to read its log." : "This run left no log.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView("Loading log…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let log):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(log.file).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    if log.truncated {
                        Label("Showing the end of a long log", systemImage: "scissors").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                ScrollView {
                    Text(log.text.isEmpty ? "The log is empty." : log.text)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .accessibilityLabel("Run log")
            }
        }
    }
}

private struct LeoTaskRunRow: View {
    let run: LeoTaskRun

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(run.startedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "Unknown time")
            Spacer()
            if let duration = run.durationMs {
                Text(Self.duration(milliseconds: duration)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        switch run.succeeded {
        case true?: "checkmark.circle.fill"
        case false?: "xmark.circle.fill"
        case nil: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch run.succeeded {
        case true?: .green
        case false?: .red
        case nil: .secondary
        }
    }

    private var accessibilityLabel: String {
        let outcome = run.succeeded.map { $0 ? "Succeeded" : "Failed, exit \(run.exitCode ?? -1)" } ?? "No exit code"
        return "\(outcome), \(run.startedAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "unknown time")"
    }

    static func duration(milliseconds: Int) -> String {
        let seconds = Double(milliseconds) / 1000
        if seconds < 1 { return "\(milliseconds) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}
