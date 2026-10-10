import AppKit
import SwiftUI

enum LeoAttachActivation {
    static func disposition(for modifierFlags: NSEvent.ModifierFlags) -> AttachDisposition {
        modifierFlags.contains(.option) ? .newWindow : .content
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
    /// B-176: a worktree branch needs the agent's GitHub owner/repo; the
    /// agent's own status doesn't matter.
    let newWorktree: Bool

    init(status: LeoAgentStatus, isPending: Bool, repo: String? = nil) {
        newWorktree = SpawnValidation.ownerRepo(repo) != nil
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
    /// A click (the event's modifiers, click count): see
    /// `LeoSidebarModel.rowClicked`.
    let click: (NSEvent.ModifierFlags, Int) -> Void
    @ObservedObject var actions: LeoAgentActions
    let error: String?
    let errorCode: String?
    /// Name characters the search query matched, drawn bold (B-009).
    var nameHighlights: [Int] = []
    /// Whether the row is in the Pinned section, and the toggle (B-010).
    var isPinned = false
    var togglePin: () -> Void = {}
    /// This row's unseen surfaced files, newest last, and the open (B-013).
    var pendingSurfacedFiles: [LeoSurfacedFile] = []
    var openSurfacedFile: (LeoSurfacedFile) -> Void = { _ in }
    /// Opens the New Agent sheet in worktree mode for this row (B-176). The
    /// sheet lives on the sidebar, so it outlives this row re-sorting or
    /// being filtered out.
    var newWorktreeAgent: () -> Void = {}
    /// B-283: the row's host advertised `agent_environments`.
    var environmentsSupported = false
    /// Whether the row sits in the Working section (grouped by attention).
    var inWorkingSection = false
    @State private var showingRename = false
    @State private var showingDelete = false

    private var availability: LeoRowActionAvailability {
        LeoRowActionAvailability(status: row.status, isPending: actions.pendingActions.contains(row.id), repo: row.repo)
    }

    var body: some View {
        LeoAgentRowContent(
            row: row, error: error, isSelected: isSelected, isPending: actions.pendingActions.contains(row.id),
            nameHighlights: nameHighlights, pendingSurfacedFiles: pendingSurfacedFiles, inWorkingSection: inWorkingSection
        )
        .contentShape(Rectangle())
        // The whole row is the target, like Finder or Mail (B-049);
        // there's no per-row button to aim for. Not tap gestures:
        // those miss clicks in a window that isn't key (a ⌘-click on
        // a background window), and the catcher reads the click's
        // own modifiers and count, so a double-click is the second
        // click (B-048). It never takes the click from the list's
        // own selection.
        .background(LeoRowClickCatcher(identity: row.id, onClick: click).accessibilityHidden(true))
        // One element per row: the name's label (name, state), then the
        // detail and time. There's no button in the row to press, so the
        // row itself is the press.
        .accessibilityElement(children: .combine)
        .accessibilityAction { LeoRowAccessibility.press(click) }
        .accessibilityAction(named: LeoRowAccessibility.pressName) { LeoRowAccessibility.press(click) }
        .contextMenu { menu }
        .sheet(isPresented: $showingRename) { LeoRenameAgentSheet(row: row, actions: actions) }
        .sheet(isPresented: $showingDelete) {
            LeoDeleteAgentSheet(row: row, actions: actions, error: error, errorCode: errorCode)
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Attach") {
            LeoAttachActivation.activate(row: row, modifierFlags: NSEvent.modifierFlags, attach: attach)
        }.disabled(!availability.attach)
        // D-104: ⌘-click's new window, for the mouse user who doesn't know it.
        Button("Open in New Window") { attach(row, .newWindow) }.disabled(!availability.attach)
        Button("New Agent in Worktree…", action: newWorktreeAgent).disabled(!availability.newWorktree)
        Button("Start") { actions.start(row) }.disabled(!availability.start)
        Button("Stop") { actions.stop(row) }.disabled(!availability.stop)
        Button("Restart") { actions.restart(row) }.disabled(!availability.restart)
        // B-054: reads the list `actions` prefetched on host selection. A
        // per-row fetch started from inside the context menu could only
        // land after the menu was already built, so the first open was empty.
        Menu("Set Template") { templateItems }
            .disabled(!availability.setTemplate)
        if environmentsSupported {
            Menu(LeoEnvironmentMenu.title) { environmentItems }
                .disabled(!availability.setTemplate)
            Menu(LeoEnvironmentSwitchMenu.title) { switchItems }
                .disabled(!availability.setTemplate)
        }
        Button("Rename…") { showingRename = true }.disabled(!availability.rename)
        Button("View Logs") { viewLogs() }.disabled(!availability.logs)
        Button("Browse Files") { browseFiles() }
        if !row.surfacedFiles.isEmpty {
            Menu("Surfaced Files") {
                ForEach(row.surfacedFiles.reversed()) { file in
                    Button(file.menuTitle) { openSurfacedFile(file) }
                }
            }
        }
        Button(LeoMenuCommands.pinToggleTitle(isPinned: isPinned), action: togglePin)
        Divider()
        Button("Delete…", role: .destructive) { showingDelete = true }.disabled(!availability.delete)
    }

    @ViewBuilder private var templateItems: some View {
        switch actions.templateList {
        case .loading:
            Text("Loading Templates…")
        case .failed(let message):
            Text("Templates unavailable: \(message)")
        case .loaded(let templates) where templates.isEmpty:
            Text("No Templates")
        case .loaded(let templates):
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

    /// B-283: built from the same entries as the Agent menu's submenu.
    @ViewBuilder private var environmentItems: some View {
        let entries = LeoEnvironmentMenu.entries(catalog: actions.environmentCatalog, current: row.environments)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .placeholder(let title):
                Text(title)
            case .toggle(let name, let isOn):
                Toggle(name, isOn: Binding(get: { isOn }, set: { _ in LeoEnvironmentChange.perform(entry, row: row, actions: actions) }))
            case .switchTo:
                EmptyView()
            case .separator:
                Divider()
            case .editOrder(let isEnabled):
                Button(LeoEnvironmentMenu.editOrderTitle) { LeoEnvironmentChange.perform(entry, row: row, actions: actions) }
                    .disabled(!isEnabled)
            case .reset(let isEnabled):
                Button(LeoEnvironmentMenu.resetTitle) { LeoEnvironmentChange.perform(entry, row: row, actions: actions) }
                    .disabled(!isEnabled)
            }
        }
    }

    /// Switch to ▸: replaces the whole list with one environment, through
    /// the same confirm as the toggles. The agent's sole environment is
    /// checked and can't be picked again.
    @ViewBuilder private var switchItems: some View {
        let entries = LeoEnvironmentSwitchMenu.entries(catalog: actions.environmentCatalog, current: row.environments)
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .placeholder(let title):
                Text(title)
            case .switchTo(let name, let isCurrent):
                Toggle(name, isOn: Binding(get: { isCurrent }, set: { _ in LeoEnvironmentChange.perform(entry, row: row, actions: actions) }))
                    .disabled(isCurrent)
            case .toggle, .separator, .editOrder, .reset:
                EmptyView()
            }
        }
    }

    /// Opens the workspace browser (B-005) on this agent in the window
    /// whose sidebar was clicked.
    private func browseFiles() {
        guard let controller = NSApp.keyWindow?.windowController as? TerminalController else {
            actions.setRowError("No terminal window available", for: row)
            return
        }
        controller.browseLeoFiles(forRow: row)
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
            guard LeoCommandLauncher.openWindow(in: controller, command: command) else {
                actions.setRowError("Unable to open a terminal window", for: row)
                return
            }
        } catch {
            actions.setRowError(error.localizedDescription, for: row)
        }
    }

}
