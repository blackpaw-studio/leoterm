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

struct LeoDeleteSheetActionAvailability {
    let delete: Bool
    let stopFirst: Bool

    init(row: LeoRowActionAvailability, errorCode: String?) {
        delete = row.delete
        stopFirst = row.stop && LeoDeleteActionState.canStopFirst(errorCode: errorCode)
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
    @State private var showingRename = false
    @State private var showingDelete = false
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
        .sheet(isPresented: $showingRename) { LeoRenameAgentSheet(row: row, actions: actions) }
        .sheet(isPresented: $showingDelete) {
            LeoDeleteAgentSheet(row: row, actions: actions, error: error, errorCode: errorCode)
        }
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
                Text(error).font(.caption).foregroundStyle(Color(nsColor: .systemRed)).lineLimit(2)
            }
            if actions.pendingActions.contains(row.id) { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var activityDot: some View {
        switch row.activity {
        case .working, .idle:
            let presentation = LeoStatusPresentation.activity(row.activity)
            Image(systemName: presentation.symbolName)
                .resizable()
                .frame(width: 7, height: 7)
                .foregroundStyle(presentation.color)
                .accessibilityLabel(presentation.accessibilityLabel)
        case .unknown:
            // No activity data yet; not an error, so no glyph is shown.
            Color.clear.frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }

    private var statusBadge: some View {
        let presentation = LeoStatusPresentation.agentStatus(row.status)
        return Text(statusText)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(presentation.color.opacity(0.18), in: Capsule())
            .foregroundStyle(presentation.color)
    }

    private var statusText: String {
        switch row.status {
        case .running: "running"
        case .starting: "starting"
        case .stopped: "stopped"
        case .unknown: "unknown"
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
        Button("Rename…") { showingRename = true }.disabled(!availability.rename)
        Button("View Logs") { viewLogs() }.disabled(!availability.logs)
        Divider()
        Button("Delete…", role: .destructive) { showingDelete = true }.disabled(!availability.delete)
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
            let command: String
            if case .remote(let name) = row.host {
                guard let configuration = runtime.hostSelection.hosts.first(where: { $0.name == name }) else {
                    throw LeoDaemonError.hostUnavailable("Remote host \(name) is not configured")
                }
                command = try LeoSSHCommand(configuration: configuration).logsShellCommand(agent: row.name)
            } else {
                command = try LeoLogsCommand.build(executablePath: runtime.resolveExecutablePath(), agentName: row.name)
            }
            guard LeoCommandLauncher.openTab(in: controller, command: command) else {
                actions.setRowError("Unable to open a terminal tab", for: row)
                return
            }
        } catch {
            actions.setRowError(error.localizedDescription, for: row)
        }
    }

}
