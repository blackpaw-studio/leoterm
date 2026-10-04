import AppKit
import SwiftUI

/// A named group of rows for the sidebar's `List`, keyed by status. Rows
/// arrive already sorted (`LeoSidebarLayout`), so grouping by first
/// occurrence preserves that order without a second sort -- and a status
/// with no rows (e.g. filtered out by a search query) never produces an
/// empty section header.
struct LeoSidebarSection: Identifiable, Equatable {
    let id: String
    let title: String
    let rows: [LeoAgentRow]
    /// Header only; the rows stay listed here but aren't shown (B-010).
    let isCollapsed: Bool

    init(id: String, title: String, rows: [LeoAgentRow], isCollapsed: Bool = false) {
        self.id = id
        self.title = title
        self.rows = rows
        self.isCollapsed = isCollapsed
    }
}

enum LeoSidebarSectioning {
    static func sections(for rows: [LeoAgentRow]) -> [LeoSidebarSection] {
        var order: [String] = []
        var rowsByKey: [String: [LeoAgentRow]] = [:]
        for row in rows {
            let key = sectionKey(for: row.status)
            if rowsByKey[key] == nil {
                order.append(key)
                rowsByKey[key] = []
            }
            rowsByKey[key]?.append(row)
        }
        return order.map { key in
            LeoSidebarSection(id: key, title: title(for: key), rows: rowsByKey[key] ?? [])
        }
    }

    static func sectionKey(for status: LeoAgentStatus) -> String {
        switch status {
        case .running: "running"
        case .starting: "starting"
        case .stopped: "stopped"
        case .unknown(let raw): "unknown:\(raw)"
        }
    }

    static func title(for key: String) -> String {
        switch key {
        case "running": return "Running"
        case "starting": return "Starting"
        case "stopped": return "Stopped"
        default:
            guard key.hasPrefix("unknown:") else { return key.capitalized }
            let raw = String(key.dropFirst("unknown:".count))
            // A daemon that reports an empty status would otherwise render a
            // blank section header with rows under it.
            return raw.isEmpty ? "Unknown" : raw.capitalized
        }
    }
}

struct LeoSidebarView: View {
    @ObservedObject var model: LeoSidebarModel
    let windowID: LeoWindowID
    @ObservedObject var actions: LeoAgentActions
    /// This window's own plain shells (B-057): per window, while `model`'s
    /// agent list is app-wide.
    @ObservedObject var terminals: LeoWindowTerminals
    /// Bumped by Agents ▸ Find Agent…; each change focuses the search field.
    let searchFocusRequest: Int
    /// The footer buttons' tooltips (B-065).
    @ObservedObject private var shortcutHints: LeoShortcutHints
    /// What the footer's buttons do: this window's File ▸ New Terminal and
    /// View ▸ Quick Terminal.
    private let buttonActions: LeoSidebarButtonActions
    @ObservedObject private var hostSelection: LeoHostSelection
    @State private var showingSpawn = false
    /// The row a "New Agent in Worktree…" sheet branches from (B-176).
    @State private var worktreeSource: LeoAgentRow?
    @State private var searchField = LeoSidebarSearchFieldHandle()
    @State private var hostsSheetModel: LeoHostsSheetModel?

    /// Main-actor so a missing `shortcutHints` (tests) can be made here.
    @MainActor init(
        model: LeoSidebarModel,
        windowID: LeoWindowID,
        actions: LeoAgentActions,
        terminals: LeoWindowTerminals,
        searchFocusRequest: Int = 0,
        shortcutHints: LeoShortcutHints? = nil,
        buttonActions: LeoSidebarButtonActions = .none
    ) {
        self.model = model
        self.windowID = windowID
        self.actions = actions
        self.terminals = terminals
        self.searchFocusRequest = searchFocusRequest
        _shortcutHints = ObservedObject(wrappedValue: shortcutHints ?? LeoShortcutHints())
        self.buttonActions = buttonActions
        _hostSelection = ObservedObject(wrappedValue: actions.hostSelection)
    }

    var body: some View {
        VStack(spacing: LeoSidebarChromeMetrics.itemSpacing) {
            LeoSidebarHeader("Agents") {
                Button {
                    showingSpawn = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Agent…")
                .accessibilityLabel("New Agent…")
                .disabled(model.isDisconnected)
            }
            Menu {
                hostMenuItem(name: "localhost", isSelected: hostSelection.selected == .local) {
                    hostSelection.select(.local)
                }
                ForEach(hostSelection.hosts) { host in
                    hostMenuItem(name: host.name, isSelected: hostSelection.selected == .remote(host.name)) {
                        hostSelection.select(.remote(host.name))
                    }
                }
                if case .failed = hostSelection.state {
                    Divider()
                    Button("Retry") { hostSelection.retry() }
                }
                Divider()
                Button("Manage Hosts…") { hostsSheetModel = hostSelection.makeHostsSheetModel() }
            } label: {
                HStack {
                    Text(hostSelection.selected.displayName)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(hostSelection.legacyTooltip ?? "Select host")
            .accessibilityLabel("Host")

            if let banner = LeoDisconnectedBanner(host: hostSelection.selected, connectivity: model.snapshot.connectivity) {
                LeoDisconnectedBannerView(banner: banner) { model.retry() }
            }

            LeoSidebarSearchField(
                text: $model.query,
                handle: searchField,
                onSubmit: { model.searchSubmit(from: windowID) },
                onCancel: searchEscape
            )
            .accessibilityLabel("Search agents")
            .leoSidebarHeaderFrame(.searchField)

            content
            if let panelError {
                Text(panelError).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
            }
            LeoSidebarButtonBar(hints: shortcutHints, perform: buttonActions.perform)
        }
        .padding(.top, LeoSidebarChromeMetrics.topInset)
        .padding(.horizontal, LeoSidebarChromeMetrics.horizontalInset)
        .padding(.bottom, LeoSidebarChromeMetrics.itemSpacing)
        .onChange(of: searchFocusRequest) { _ in searchField.focus() }
        #if DEBUG
        .onAppear { LeoLaunchTiming.mark("sidebarAppeared", "connectivity=\(model.snapshot.connectivity) rows=\(model.snapshot.rows.count)") }
        #endif
        .sheet(isPresented: $showingSpawn) {
            SpawnAgentSheet(model: model, actions: actions) { row, disposition in
                model.requestAttach(row, from: windowID, disposition: disposition)
            }
        }
        .sheet(item: $worktreeSource) { source in
            SpawnAgentSheet(model: model, actions: actions, source: source) { row, disposition in
                model.requestAttach(row, from: windowID, disposition: disposition)
            }
        }
        .sheet(item: $hostsSheetModel) { sheetModel in
            LeoHostsSheet(model: sheetModel) { hostsSheetModel = nil }
        }
        .sheet(item: startPromptBinding) { item in LeoStartAgentSheet(model: model, prompt: item.prompt) }
    }

    private var panelError: String? { model.panelError }

    /// This window's "Start <name>?" prompt (B-049); the model holds one
    /// per window, so the sheet shows only where the click was.
    private var startPromptBinding: Binding<LeoStartPromptSheetItem?> {
        Binding(
            get: { model.startPrompt(in: windowID).map(LeoStartPromptSheetItem.init(prompt:)) },
            set: { newValue in
                guard newValue == nil, let prompt = model.startPrompt(in: windowID) else { return }
                model.cancelStartPrompt(prompt.id)
            }
        )
    }

    /// The agent list (or what stands in for it), with this window's
    /// Terminals section: the shells don't need the daemon, so they show
    /// whatever state the agents are in.
    ///
    /// One list, in one place, whatever it shows (B-099): a filter that
    /// matches nothing empties it under "No matches" rather than replacing
    /// it, and the agents arriving fill the list the Terminals were in. So
    /// the list's reveal of the selected terminal row (B-067) follows the
    /// list's own changes, never a new list's first appearance, which can
    /// come before AppKit has built its table.
    @ViewBuilder private var content: some View {
        if !listsAgents { agentState }
        if listsAgents || showsTerminals {
            sidebarList(agentSections: listsAgents ? model.sections : [], agentsInert: listsAgents && model.isDisconnected)
                .overlay {
                    if listsAgents && model.showsNoMatches {
                        Text("No matches").allowsHitTesting(false)
                    }
                }
        }
    }

    /// Rows to list: connected (or disconnected, dimmed) with agents, even
    /// when the filter matches none of them.
    private var listsAgents: Bool {
        switch model.snapshot.connectivity {
        case .connected, .disconnected: !model.snapshot.rows.isEmpty
        case .loading, .failed: false
        }
    }

    /// The Terminals section hides when the window has no shells, and
    /// while the filter (which searches agents) has text.
    private var showsTerminals: Bool {
        !terminals.rows.isEmpty && !LeoSidebarLayout.isFiltering(model.query)
    }

    @ViewBuilder private var agentState: some View {
        switch model.snapshot.connectivity {
        case .loading:
            stateView { ProgressView(); Text("Loading agents…") }
        case .failed(let message):
            let panel = LeoConnectionFailurePanel(message: message, hint: hostSelection.state.failureHint)
            stateView {
                Text(panel.message).multilineTextAlignment(.center).textSelection(.enabled)
                if let hint = panel.hint, let ssh = hostSelection.selectedConfiguration?.sshTarget {
                    Text(hint).font(.caption).multilineTextAlignment(.center)
                    Button("Open SSH") { model.sshRequested(ssh) }
                }
                Button("Retry") { model.retry() }
                Button("Start daemon") { model.startDaemonRequested() }
            }
        case .connected where model.snapshot.rows.isEmpty:
            stateView {
                Text("No Agents").font(.headline)
                Text("Spawn an agent to start working with it from this window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("New Agent…") { showingSpawn = true }
            }
        case .disconnected where model.snapshot.rows.isEmpty:
            // The banner above says what happened and offers Retry.
            stateView {
                if hostSelection.selected == .local {
                    Button("Start daemon") { model.startDaemonRequested() }
                }
            }
        case .connected, .disconnected:
            // Agents to list: the list shows them, or "No matches" over it.
            EmptyView()
        }
    }

    /// How far a disconnected sidebar's stale rows are dimmed.
    private static let inertOpacity = 0.45

    /// Agent sections, then this window's Terminals. Disconnected, the
    /// agent rows stay listed but dimmed and inert until a Retry lands a
    /// fresh list (D-061); the terminals don't depend on the daemon.
    private func sidebarList(agentSections: [LeoSidebarSection], agentsInert: Bool) -> some View {
        // Selection is required (`SelectionValue` is the optional ID
        // itself, so each row's tag is `Optional(id)`): the table then
        // never toggles the selected row off on ⌘-click, which here opens
        // a new window (B-048, D-104). `nil` still shows no selection.
        ScrollViewReader { proxy in
            List<LeoSidebarItemID?, _>(selection: selectionBinding) {
                ForEach(agentSections) { section in
                    Section(header: sectionHeader(section)) {
                        agentRows(section)
                            .disabled(agentsInert)
                            .opacity(agentsInert ? Self.inertOpacity : 1)
                            .accessibilityHint(agentsInert ? "Disconnected" : "")
                    }
                }
                if showsTerminals { terminalSection }
            }
            .listStyle(.sidebar)
            .leoRevealsTerminalRow(terminals.selection, isListed: showsTerminals, listsAgents: listsAgents, proxy: proxy)
            .leoLandsWhenTerminalsClose(
                // Its header's row and each terminal row `terminalSection` lists.
                sectionRows: showsTerminals ? terminals.list.labels.count + 1 : 0,
                isFiltering: LeoSidebarLayout.isFiltering(model.query),
                landing: LeoTerminalsSectionExit.landing(selectedAgent: model.selection, in: agentSections),
                terminalsWillChange: terminals.objectWillChange,
                proxy: proxy
            )
        }
        .overlay(alignment: .bottomTrailing) {
            // A key equivalent, so it sees Return before the search
            // field does; there Return means the top match instead.
            // Both are a click on a row (B-049): the top match, or the
            // selection. Arrow keys only move the selection.
            Button("") {
                if searchField.hasFocus {
                    model.searchSubmit(from: windowID)
                } else {
                    LeoSidebarSelection.activate(model: model, terminals: terminals, from: windowID)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .opacity(0)
            .disabled(!LeoSidebarSelection.canActivate(model: model, terminals: terminals))
            .accessibilityHidden(true)
        }
    }

    private var terminalSection: some View {
        Section(header: Text("Terminals")) {
            ForEach(terminals.list.labels) { label in
                LeoTerminalRowView(label: label, terminals: terminals)
                    .tag(Optional(LeoSidebarItemID.terminal(label.id)))
                    .id(LeoSidebarItemID.terminal(label.id))
            }
        }
    }

    /// The window's selection: its terminal row, else the app-wide agent.
    private var selectionBinding: Binding<LeoSidebarItemID?> {
        Binding(
            get: { LeoSidebarSelection.current(model: model, terminals: terminals) },
            set: { LeoSidebarSelection.select($0, model: model, terminals: terminals) }
        )
    }

    private func agentRows(_ section: LeoSidebarSection) -> some View {
        ForEach(section.isCollapsed ? [] : section.rows) { row in
            LeoAgentRowView(
                row: row,
                isSelected: LeoSidebarSelection.current(model: model, terminals: terminals) == .agent(row.id),
                attach: { row, disposition in model.requestAttach(row, from: windowID, disposition: disposition) },
                click: { model.rowClicked(row, modifierFlags: $0, clickCount: $1, from: windowID) },
                actions: actions,
                error: model.rowErrors[row.id],
                errorCode: model.rowErrorCodes[row.id],
                nameHighlights: model.searchHighlights(for: row),
                isPinned: model.isPinned(row.id),
                togglePin: { model.togglePin(row.id) },
                pendingSurfacedFiles: model.pendingSurfacedFiles(for: row),
                openSurfacedFile: { model.openSurfacedFile($0, for: row) },
                newWorktreeAgent: { worktreeSource = row }
            )
            .tag(Optional(LeoSidebarItemID.agent(row.id)))
            .id(LeoSidebarItemID.agent(row.id))
        }
    }

    /// A section title with a disclosure chevron (B-010). While the filter
    /// is non-empty every match shows, so there's nothing to collapse.
    @ViewBuilder private func sectionHeader(_ section: LeoSidebarSection) -> some View {
        if LeoSidebarLayout.isFiltering(model.query) {
            Text(section.title)
        } else {
            LeoSidebarSectionHeader(title: section.title, isCollapsed: section.isCollapsed) {
                model.toggleCollapsed(section.id)
            }
        }
    }

    private func stateView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func searchEscape() {
        switch model.searchEscape() {
        case .cleared: break
        case .leaveField: searchField.focusTerminal()
        }
    }

    /// A single host entry in the host picker menu. Selection is conveyed by
    /// the menu's own checkmark (via `Toggle`, which macOS renders as a
    /// checked menu item), and connection state by an SF Symbol + semantic
    /// color from `LeoStatusPresentation` -- never by a typed character.
    ///
    /// Only the currently *selected* remote host has a live connection state
    /// to show (see `LeoHostSelection`); other configured hosts show a
    /// neutral glyph until they're selected.
    private func hostMenuItem(name: String, isSelected: Bool, select: @escaping () -> Void) -> some View {
        let presentation = LeoStatusPresentation.hostConnection(
            isSelected: isSelected,
            state: isSelected ? hostSelection.state : nil
        )
        return Toggle(isOn: Binding(get: { isSelected }, set: { _ in select() })) {
            Label {
                Text(name)
            } icon: {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(presentation.color)
            }
        }
        .accessibilityLabel("\(name), \(presentation.accessibilityLabel)")
    }
}

/// "Disconnected from <host>" with the sanitized reason and Retry (D-061).
/// Calm: one static banner, no motion beyond the system's small spinner
/// while a Retry is in flight.
struct LeoDisconnectedBannerView: View {
    let banner: LeoDisconnectedBanner
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout.weight(.semibold))
                Text(banner.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(banner.reasonLineLimit)
                    .truncationMode(.tail)
                    .help(banner.reasonHelp)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if banner.isRetrying {
                ProgressView().controlSize(.small).accessibilityLabel("Reconnecting")
            } else {
                Button("Retry", action: retry).controlSize(.small)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.title)
    }
}
