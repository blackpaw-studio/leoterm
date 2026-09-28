import AppKit
import SwiftUI

enum LeoAttachActivation {
    static func disposition(for modifierFlags: NSEvent.ModifierFlags) -> AttachDisposition {
        modifierFlags.contains(.option) ? .newWindow : .reuseOrTab
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
    @State private var templates: [LeoTemplate] = []
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var templateLoadError: String?
    /// The room the subtitle text has, once measured (B-043).
    @State private var subtitleWidth: CGFloat?

    private var availability: LeoRowActionAvailability {
        LeoRowActionAvailability(status: row.status, isPending: actions.pendingActions.contains(row.id))
    }

    var body: some View {
        HStack(spacing: 8) {
            activityDot
            rowDetails
                .contentShape(Rectangle())
                // The whole row is the target, like Finder or Mail (B-049);
                // there's no per-row button to aim for. Not tap gestures:
                // those miss clicks in a window that isn't key (a ⌘-click on
                // a background window), and the catcher reads the click's
                // own modifiers and count, so a double-click is the second
                // click (B-048). It never takes the click from the list's
                // own selection.
                .background(LeoRowClickCatcher(identity: row.id, onClick: click))
        }
        .contentShape(Rectangle())
        // No button in the row to press, so the row itself is the press.
        .accessibilityAction { LeoRowAccessibility.press(click) }
        .accessibilityAction(named: LeoRowAccessibility.pressName) { LeoRowAccessibility.press(click) }
        .contextMenu { menu }
        .sheet(isPresented: $showingRename) { LeoRenameAgentSheet(row: row, actions: actions) }
        .sheet(isPresented: $showingDelete) {
            LeoDeleteAgentSheet(row: row, actions: actions, error: error, errorCode: errorCode)
        }
    }

    private var nameText: Text {
        LeoFuzzyMatcher.highlightRuns(name: row.name, offsets: nameHighlights).reduce(Text("")) { text, run in
            text + Text(run.text).fontWeight(run.isMatched ? .bold : nil)
        }
    }

    private var rowDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                nameText
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .accessibilityLabel(LeoStatusPresentation.rowAccessibilityLabel(row))
                Spacer(minLength: 4)
                attentionBadge
                statusBadge
            }
            subtitleLine
            // The current task as the daemon's last snapshot reported it
            // (already sanitized); the tooltip holds what the line cuts.
            if let task = presentation().task {
                Text(task).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(task)
            }
            if let error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(Color(nsColor: .systemRed)).lineLimit(2)
            }
            if actions.pendingActions.contains(row.id) { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var activityDot: some View {
        if row.attention == nil, row.activity != .unknown {
            let presentation = LeoStatusPresentation.activity(row.activity)
            Image(systemName: presentation.symbolName)
                .resizable()
                .frame(width: 7, height: 7)
                .foregroundStyle(presentation.color)
                .accessibilityHidden(true)
        } else {
            // No activity data yet (not an error), or the attention badge
            // already says it: no glyph.
            Color.clear.frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }

    private func presentation(now: Date? = nil) -> LeoAgentRowPresentation {
        LeoAgentRowPresentation(row: row, isSelected: isSelected, now: now)
    }

    /// Only a row with a "last active" time re-renders, once a minute --
    /// never per event.
    @ViewBuilder private var subtitleLine: some View {
        if row.metadata?.lastActiveAt != nil || row.metadata?.isWorking == true {
            TimelineView(.everyMinute) { context in subtitleLine(presentation(now: context.date)) }
        } else {
            subtitleLine(presentation())
        }
    }

    /// The surfaced-files glyph lives on the subtitle line, never the name
    /// line, so it costs the name no width.
    @ViewBuilder private func subtitleLine(_ presentation: LeoAgentRowPresentation) -> some View {
        if presentation.subtitle != nil || !pendingSurfacedFiles.isEmpty {
            HStack(spacing: 4) {
                if let subtitle = presentation.subtitle {
                    // VoiceOver already hears the state on the name's label, so
                    // the subtitle reads only the template and the time -- the
                    // full ones, like the tooltip, even when the line drops the
                    // template for width.
                    subtitleText(fitted(subtitle)).font(.caption)
                        .help(subtitle.text)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(subtitle.accessibilityLabel)
                        .accessibilityHidden(subtitle.accessibilityLabel.isEmpty)
                        // Fills the line so its width is the room the text
                        // has, whatever the text currently shows.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { subtitleWidth = $0 }
                } else {
                    Spacer(minLength: 4)
                }
                surfacedFilesGlyph
            }
        }
    }

    /// The line as it fits the measured room; whole until the first measure.
    private func fitted(_ subtitle: LeoAgentRowPresentation.Subtitle) -> LeoAgentRowPresentation.Subtitle {
        guard let subtitleWidth else { return subtitle }
        return subtitle.fitting(width: subtitleWidth, measure: LeoAgentRowPresentation.Subtitle.captionWidth)
    }

    /// "claude · Needs Input · 5m": the template and the last-active time
    /// in secondary, the attention state word in its state color. One line;
    /// when it's too narrow the template truncates first (dropping outright
    /// below a few legible characters, see `fitted`), then the state,
    /// and the time never does (each part is its own text with its own
    /// layout priority; the time is fixed-size).
    private func subtitleText(_ subtitle: LeoAgentRowPresentation.Subtitle) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(subtitle.segments.enumerated()), id: \.offset) { _, segment in
                subtitleSegment(segment)
            }
        }
    }

    @ViewBuilder private func subtitleSegment(_ segment: LeoAgentRowPresentation.Subtitle.Segment) -> some View {
        let separator = Text(segment.hasSeparator ? LeoAgentRowPresentation.Subtitle.separator : "").foregroundColor(.secondary)
        let body = switch segment.tint {
        case .secondary: Text(segment.text).foregroundColor(.secondary)
        case .state(let tint): Text(segment.text).foregroundColor(tint)
        }
        let text = (separator + body).lineLimit(1).truncationMode(.tail).layoutPriority(segment.truncation.layoutPriority)
        if segment.truncation == .never {
            text.fixedSize()
        } else {
            text
        }
    }

    /// Static (no animation), fixed-width, icon-only attention badge so it
    /// never takes width from the name; the state word is on the subtitle
    /// line. The symbol's shape carries the state for color-blind users and
    /// is hidden from VoiceOver, which reads the state from the name's label.
    @ViewBuilder private var attentionBadge: some View {
        if let badge = presentation().badge {
            Image(systemName: badge.symbolName)
                .font(.caption)
                .frame(width: 14, height: 14)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(badge.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(badge.tint)
                .fixedSize()
                .layoutPriority(1)
                .accessibilityHidden(true)
        }
    }

    /// Static, secondary-colored: files the agent
    /// surfaced that haven't been opened. Calm on purpose -- no tint, no
    /// motion; it isn't "needs input". The tooltip lists them.
    @ViewBuilder private var surfacedFilesGlyph: some View {
        if let indicator = LeoSurfacedFilesIndicator(pending: pendingSurfacedFiles) {
            HStack(spacing: 2) {
                Image(systemName: LeoSurfacedFilesIndicator.symbolName)
                Text(indicator.countText).monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(indicator.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(indicator.accessibilityLabel)
        }
    }

    @ViewBuilder private var statusBadge: some View {
        // A running agent is the expected state (already conveyed by the
        // activity dot), so the badge only surfaces exceptions: stopped,
        // starting, failed, unknown. That both reduces list noise and frees
        // width for the name. VoiceOver still gets the status on every row
        // via the accessibility label on the name text above.
        if row.status != .running {
            let presentation = LeoStatusPresentation.agentStatus(row.status)
            Text(statusText)
                .font(.caption2)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(presentation.color.opacity(0.18), in: Capsule())
                .foregroundStyle(presentation.color)
        }
    }

    private var statusText: String {
        switch row.status {
        case .running: "running"
        case .starting: "starting"
        case .stopped: "stopped"
        case .unknown: "unknown"
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Attach") {
            LeoAttachActivation.activate(row: row, modifierFlags: NSEvent.modifierFlags, attach: attach)
        }.disabled(!availability.attach)
        // B-047: ⌘-click's new tab, for the mouse user who doesn't know it.
        Button("Attach in New Tab") { attach(row, .newTab) }.disabled(!availability.attach)
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

    /// Opens the workspace browser (B-005) on this agent in the window
    /// whose sidebar was clicked.
    private func browseFiles() {
        guard let controller = NSApp.keyWindow?.windowController as? TerminalController else {
            actions.setRowError("No terminal window available", for: row)
            return
        }
        controller.browseLeoFiles(for: LeoEditorAgentContext(host: row.host, name: row.name, workspace: row.workspace))
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
