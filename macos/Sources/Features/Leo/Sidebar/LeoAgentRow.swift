import AppKit
import SwiftUI

enum LeoAttachActivation {
    enum Source {
        case button
        case rowDoubleClick
        case keyboard
    }

    static func disposition(for modifierFlags: NSEvent.ModifierFlags) -> AttachDisposition {
        modifierFlags.contains(.option) ? .newWindow : .reuseOrTab
    }

    static func activate(
        source _: Source,
        row: LeoAgentRow,
        attach: (LeoAgentRow, AttachDisposition) -> Void
    ) {
        activate(row: row, modifierFlags: NSEvent.modifierFlags, attach: attach)
    }

    static func activate(
        row: LeoAgentRow,
        modifierFlags: NSEvent.ModifierFlags,
        attach: (LeoAgentRow, AttachDisposition) -> Void
    ) {
        attach(row, disposition(for: modifierFlags))
    }
}

struct LeoRowActionAvailability {
    let start: Bool
    let stop: Bool
    let restart: Bool
    let setTemplate: Bool
    let rename: Bool
    let delete: Bool
    let attach: Bool
    let logs: Bool

    init(status: LeoAgentStatus, isPending: Bool) {
        let editable = !isPending && (status == .stopped || status == .running)
        start = !isPending && status == .stopped
        stop = !isPending && status == .running
        restart = !isPending && status == .running
        setTemplate = editable
        rename = editable
        delete = editable
        attach = !isPending
        logs = !isPending
    }
}

enum LeoDeleteActionState {
    static func canStopFirst(errorCode: String?) -> Bool {
        errorCode == "agent_still_running"
    }
}

struct LeoAgentRowView: View {
    let row: LeoAgentRow
    let isSelected: Bool
    let attach: (LeoAgentRow, AttachDisposition) -> Void
    @ObservedObject var actions: LeoAgentActions
    let error: String?
    let errorCode: String?
    @State private var templates: [LeoTemplate] = []
    @State private var renameValue = ""
    @State private var deletePlan: LeoDeletePlan?
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var forceDelete = false
    @State private var deleteBranch = false
    @State private var templateLoadError: String?

    private var availability: LeoRowActionAvailability {
        LeoRowActionAvailability(status: row.status, isPending: actions.pendingActions.contains(row.id))
    }

    var body: some View {
        HStack(spacing: 8) {
            activityDot
            rowDetails
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { activate(source: .rowDoubleClick) }
            Button("Attach") { activate(source: .button) }
                .buttonStyle(.borderless)
                .disabled(!availability.attach)
                .accessibilityLabel("Attach to \(row.name)")
        }
        .contentShape(Rectangle())
        .contextMenu { menu }
        .sheet(isPresented: $showingRename) { renameSheet }
        .sheet(isPresented: $showingDelete) { deleteSheet }
    }

    private var rowDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                statusBadge
            }
            if let template = row.template, !template.isEmpty {
                Text(template).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let detail = row.actionDetail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if actions.pendingActions.contains(row.id) { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var activityDot: some View {
        switch row.activity {
        case .working:
            Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Working")
        case .idle:
            Circle().fill(.gray).frame(width: 7, height: 7).accessibilityLabel("Idle")
        case .unknown:
            Color.clear.frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.18), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusText: String {
        switch row.status {
        case .running: "running"
        case .starting: "starting"
        case .stopped: "stopped"
        case .unknown: "unknown"
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .running: .green
        case .starting: .orange
        case .stopped: .secondary
        case .unknown: .secondary
        }
    }

    private func activate(source: LeoAttachActivation.Source) {
        LeoAttachActivation.activate(source: source, row: row, attach: attach)
    }

    @ViewBuilder private var menu: some View {
        Button("Attach") { activate(source: .button) }.disabled(!availability.attach)
        Button("Start") { actions.start(row) }.disabled(!availability.start)
        Button("Stop") { actions.stop(row) }.disabled(!availability.stop)
        Button("Restart") { actions.restart(row) }.disabled(!availability.restart)
        Menu("Set Template") {
            if let templateLoadError {
                Text("Templates unavailable: \(templateLoadError)")
            } else {
                ForEach(templates) { template in
                Button { actions.setTemplate(row, template: template.name) } label: {
                    HStack {
                        Text(template.name)
                        if template.name == row.template { Image(systemName: "checkmark") }
                    }
                }
            }
            }
        }
        .disabled(!availability.setTemplate)
        .task {
            do { templates = try await actions.templates() } catch { templateLoadError = error.localizedDescription }
        }
        Button("Rename…") { renameValue = row.name; showingRename = true }.disabled(!availability.rename)
        Button("View Logs") { viewLogs() }.disabled(!availability.logs)
        Divider()
        Button("Delete…", role: .destructive) { requestDeletePlan() }.disabled(!availability.delete)
    }

    private func viewLogs() {
        guard let controller = NSApp.keyWindow?.windowController as? TerminalController else {
            actions.setRowError("No terminal window available", for: row)
            return
        }
        do {
            guard let runtime = (NSApp.delegate as? AppDelegate)?.leoRuntime else {
                throw LeoDaemonError.transport("Leo runtime unavailable")
            }
            let command = try LeoLogsCommand.build(executablePath: runtime.resolveExecutablePath(), agentName: row.name)
            LeoCommandLauncher.openTab(in: controller, command: command)
        } catch {
            actions.setRowError(error.localizedDescription, for: row)
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(row.name)").font(.headline)
            TextField("Name", text: $renameValue)
            if let validation = SpawnValidation.rename(renameValue, current: row.name) {
                Text(validation).foregroundStyle(.red)
            }
            HStack { Spacer(); Button("Cancel") { showingRename = false }; Button("Rename") {
                actions.rename(row, newName: renameValue)
                showingRename = false
            }.disabled(SpawnValidation.rename(renameValue, current: row.name) != nil) }
        }.padding().frame(width: 360)
    }

    @ViewBuilder private var deleteSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete \(row.name)?").font(.headline)
            if let deletePlan {
                if let path = deletePlan.worktreePath { Text("Worktree: \(path)") }
                if let branch = deletePlan.branch { Text("Branch: \(branch)") }
                if deletePlan.branch != nil { Toggle("Also delete branch", isOn: $deleteBranch) }
            }
            if let error, LeoDeleteActionState.canStopFirst(errorCode: errorCode) {
                Text(error).foregroundStyle(.red)
                Button("Stop first") { actions.stop(row) }
            } else if let error { Text(error).foregroundStyle(.red) }
            Toggle("Force", isOn: $forceDelete)
            HStack { Spacer(); Button("Cancel") { showingDelete = false }; Button("Delete", role: .destructive) {
                actions.delete(row, force: forceDelete, deleteBranch: deleteBranch) { showingDelete = false }
            } }
        }.padding().frame(width: 420)
    }

    private func requestDeletePlan() {
        actions.deletePlan(row) { plan in
            deletePlan = plan
            deleteBranch = false
            forceDelete = false
            showingDelete = true
        }
    }
}
