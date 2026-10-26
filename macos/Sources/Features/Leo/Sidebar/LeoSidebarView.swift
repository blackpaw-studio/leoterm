import AppKit
import SwiftUI
import SystemConfiguration
import LeoKit

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
    /// False for Needs You: always open, so its header has no chevron.
    let isCollapsible: Bool
    /// The header carries the row count.
    let showsCount: Bool
    /// The count reads in orange (Needs You).
    let isAlert: Bool

    init(
        id: String, title: String, rows: [LeoAgentRow], isCollapsed: Bool = false,
        isCollapsible: Bool = true, showsCount: Bool = false, isAlert: Bool = false
    ) {
        self.id = id
        self.title = title
        self.rows = rows
        self.isCollapsed = isCollapsed
        self.isCollapsible = isCollapsible
        self.showsCount = showsCount
        self.isAlert = isAlert
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
        case .restoring: "restoring"
        case .stopped: "stopped"
        case .unknown(let raw): "unknown:\(raw)"
        }
    }

    static func title(for key: String) -> String {
        switch key {
        case "running": return "Running"
        case "starting": return "Starting"
        case "restoring": return LeoStatusPresentation.restoringTitle
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

/// The machine a header's "New Agent Here…" sheet is for.
private struct LeoMachineSpawnItem: Identifiable {
    let host: LeoHostID
    var id: LeoHostID { host }
}

struct LeoSidebarView: View {
    @ObservedObject var model: LeoSidebarModel
    let windowID: LeoWindowID
    @ObservedObject var actions: LeoAgentActions
    /// This window's own plain shells (B-057): per window, while `model`'s
    /// agent list is app-wide.
    @ObservedObject var terminals: LeoWindowTerminals
    /// Unread chat messages per agent, for the row badges.
    @ObservedObject var unread: LeoChatUnreadStore
    /// Bumped by Agents ▸ Find Agent…; each change focuses the search field.
    let searchFocusRequest: Int
    /// The footer buttons' tooltips (B-065).
    @ObservedObject private var shortcutHints: LeoShortcutHints
    /// What the footer's buttons do: this window's File ▸ New Terminal and
    /// View ▸ Quick Terminal.
    private let buttonActions: LeoSidebarButtonActions
    /// When the selected terminal row's reveal is armed (B-149).
    private let revealScheduler: LeoRevealScheduler
    @State private var showingSpawn = false
    /// The machine a header's "New Agent Here…" spawns on.
    @State private var spawnMachine: LeoMachineSpawnItem?
    /// How each machine's stats are drawn (Settings ▸ Machines ▸ Stats style).
    @AppStorage(LeoStatsStyle.defaultsKey) private var statsStyleRaw = LeoStatsStyle.default.rawValue
    /// The row a "New Agent in Worktree…" sheet branches from (B-176).
    @State private var worktreeSource: LeoAgentRow?
    @State private var searchField = LeoSidebarSearchFieldHandle()

    /// Main-actor so a missing `shortcutHints` (tests) can be made here.
    @MainActor init(
        model: LeoSidebarModel,
        windowID: LeoWindowID,
        actions: LeoAgentActions,
        terminals: LeoWindowTerminals,
        unread: LeoChatUnreadStore? = nil,
        searchFocusRequest: Int = 0,
        shortcutHints: LeoShortcutHints? = nil,
        buttonActions: LeoSidebarButtonActions = .none,
        revealScheduler: LeoRevealScheduler = .nextTurn
    ) {
        self.model = model
        self.windowID = windowID
        self.actions = actions
        self.terminals = terminals
        _unread = ObservedObject(wrappedValue: unread ?? LeoChatUnreadStore())
        self.searchFocusRequest = searchFocusRequest
        _shortcutHints = ObservedObject(wrappedValue: shortcutHints ?? LeoShortcutHints())
        self.buttonActions = buttonActions
        self.revealScheduler = revealScheduler
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
                .disabled(!model.hasConnectedMachine)
            }

            if let banner = model.appLocationBanner {
                LeoAppLocationBannerView(banner: banner) { model.moveToApplicationsRequested() }
            }

            if let banner = model.managedBanner {
                LeoManagedBannerView(banner: banner) { model.managedBannerActionRequested($0) }
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
        .onAppear { LeoLaunchTiming.mark("sidebarAppeared", "machines=\(model.machineHosts.count) rows=\(model.rows.count)") }
        #endif
        .sheet(isPresented: $showingSpawn) {
            SpawnAgentSheet(model: model, actions: actions) { row, disposition in
                model.requestAttach(row, from: windowID, disposition: disposition)
            }
        }
        .sheet(item: $spawnMachine) { item in
            SpawnAgentSheet(model: model, actions: actions, context: item.host) { row, disposition in
                model.requestAttach(row, from: windowID, disposition: disposition)
            }
        }
        .sheet(item: $worktreeSource) { source in
            SpawnAgentSheet(model: model, actions: actions, source: source) { row, disposition in
                model.requestAttach(row, from: windowID, disposition: disposition)
            }
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

    /// One section per machine, with this window's Terminals section: the
    /// shells don't need a daemon, so they show whatever state the machines
    /// are in.
    ///
    /// One list, in one place, whatever it shows (B-099, B-148): a filter
    /// that matches nothing empties it under "No matches" rather than
    /// replacing it, and the machines connecting, failing or arriving fill
    /// the list the Terminals were in. So the list's reveal of the selected
    /// terminal row (B-067) follows the list's own changes, never a new
    /// list's first appearance, which can come before AppKit has built its
    /// table.
    @ViewBuilder private var content: some View {
        sidebarList(machines: shownMachines)
            .overlay {
                if model.showsNoMatches {
                    Text("No matches").allowsHitTesting(false)
                }
            }
    }

    /// While the filter has text only machines with matches are listed.
    private var shownMachines: [LeoMachineSection] {
        LeoSidebarLayout.isFiltering(model.query) ? model.machineSections.filter { !$0.sections.isEmpty } : model.machineSections
    }

    private var statsStyle: LeoStatsStyle { LeoStatsStyle(storedValue: statsStyleRaw) }

    /// The Mac's name for the hover on This Mac's header. Read once from
    /// the system configuration store, which never waits on a name lookup
    /// the way `Host` can.
    private static let hostName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "This Mac"

    /// Whether the window has shells: while it does, the list stays
    /// mounted, whatever the filter or the agents are doing (B-148).
    private var hasTerminals: Bool { !terminals.rows.isEmpty }

    /// The Terminals section hides when the window has no shells, and
    /// while the filter (which searches agents) has text.
    private var showsTerminals: Bool {
        hasTerminals && !LeoSidebarLayout.isFiltering(model.query)
    }

    /// Each machine's section, then this window's Terminals. An offline
    /// machine folds to its header and a card saying why; the terminals
    /// don't depend on any daemon.
    private func sidebarList(machines: [LeoMachineSection]) -> some View {
        // Selection is required (`SelectionValue` is the optional ID
        // itself, so each row's tag is `Optional(id)`): the table then
        // never toggles the selected row off on ⌘-click, which here opens
        // a new window (B-048, D-104). `nil` still shows no selection.
        ScrollViewReader { proxy in
            List<LeoSidebarItemID?, _>(selection: selectionBinding) {
                ForEach(machines) { machine in machineSection(machine) }
                if showsTerminals { terminalSection }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, LeoDispatchRowMetrics.sidebarRowSize)
            .leoRevealsTerminalRow(
                terminals.selection, isListed: showsTerminals, listsAgents: !model.rows.isEmpty, scheduler: revealScheduler, proxy: proxy
            )
            .leoLandsWhenTerminalsClose(
                // Its header's row and each terminal row `terminalSection` lists.
                sectionRows: showsTerminals ? terminals.list.labels.count + 1 : 0,
                isFiltering: LeoSidebarLayout.isFiltering(model.query),
                landing: LeoTerminalsSectionExit.landing(selectedAgent: model.selection, in: machines.flatMap(\.sections)),
                terminalsWillChange: terminals.objectWillChange,
                proxy: proxy
            )
        }
        .overlay(alignment: .bottomTrailing) {
            // A key equivalent, so it sees Return before the search
            // field does; there Return means the top match instead.
            // Both are a click on a row (B-049): the top match, or the
            // selection. Arrow keys only move the selection. Matched
            // by key, so ⌃C stays the terminal's (B-287).
            LeoSidebarReturnKey(isEnabled: LeoSidebarSelection.canActivate(model: model, terminals: terminals)) {
                if searchField.hasFocus {
                    model.searchSubmit(from: windowID)
                } else {
                    LeoSidebarSelection.activate(model: model, terminals: terminals, from: windowID)
                }
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func machineSection(_ machine: LeoMachineSection) -> some View {
        let presentation = LeoMachineHeaderPresentation(
            section: machine, style: statsStyle, hostName: Self.hostName, now: Date()
        )
        Section(header: machineHeader(machine.host, presentation)) {
            if presentation.isOffline {
                offlineCard(machine.host, presentation)
            } else if machine.connectivity == .loading {
                machineNote("Loading agents…", showsProgress: true)
            } else if !isMachineFolded(presentation) {
                machineRows(machine)
            }
        }
    }

    /// The filter shows every match, so it opens a folded machine.
    private func isMachineFolded(_ presentation: LeoMachineHeaderPresentation) -> Bool {
        presentation.isCollapsed && !LeoSidebarLayout.isFiltering(model.query)
    }

    private func machineHeader(_ host: LeoHostID, _ presentation: LeoMachineHeaderPresentation) -> some View {
        LeoMachineSectionHeader(
            host: host, presentation: presentation, style: statsStyle,
            actions: LeoMachineHeaderActions(
                toggle: { model.toggleMachineCollapsed(host) },
                newAgentHere: { spawnMachine = LeoMachineSpawnItem(host: host) },
                reconnect: { model.reconnectRequested(host) },
                editMachine: { model.editMachineRequested(host) },
                disable: { model.disableMachineRequested(host) }
            )
        )
    }

    private func offlineCard(_ host: LeoHostID, _ presentation: LeoMachineHeaderPresentation) -> some View {
        LeoMachineOfflineCard(
            presentation: presentation,
            failureHint: model.connectionFailureHint(host),
            reconnect: { model.reconnectRequested(host) },
            openSSH: { model.sshRequested($0) },
            startDaemon: host == .local ? (model.daemonStartAction.title, { model.startDaemonTapped() }) : nil
        )
        .listRowInsets(LeoDispatchRowMetrics.agentRowInsets)
    }

    /// A machine's own sections (Needs You, Pinned, then the groups), each
    /// under a small title row, or a note when it has no agents.
    @ViewBuilder private func machineRows(_ machine: LeoMachineSection) -> some View {
        if machine.sections.isEmpty {
            if !LeoSidebarLayout.isFiltering(model.query) { machineNote("No agents", showsProgress: false) }
        } else {
            ForEach(machine.sections) { section in
                subsectionHeader(section, host: machine.host)
                agentRows(section)
            }
        }
    }

    private func machineNote(_ text: String, showsProgress: Bool) -> some View {
        HStack(spacing: 6) {
            if showsProgress { ProgressView().controlSize(.small) }
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .listRowInsets(LeoDispatchRowMetrics.agentRowInsets)
    }

    /// A machine's status group (Needs You, Running…) as a title row: a
    /// `List` section can't nest, so the machine owns the real `Section`.
    @ViewBuilder private func subsectionHeader(_ section: LeoSidebarSection, host: LeoHostID) -> some View {
        Group {
            if LeoSidebarLayout.isFiltering(model.query) {
                Text(section.title)
            } else {
                LeoSidebarSectionHeader(section: section) { model.toggleCollapsed(section.id, host: host) }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .listRowInsets(LeoDispatchRowMetrics.agentRowInsets)
    }

    private var terminalSection: some View {
        Section(header: Text("Terminals")) {
            ForEach(terminals.list.labels) { label in
                LeoTerminalRowView(label: label, terminals: terminals)
                    .frame(minHeight: LeoDispatchRowMetrics.terminalRowHeight)
                    .listRowInsets(EdgeInsets())
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
                newWorktreeAgent: { worktreeSource = row },
                environmentsSupported: model.features(for: row.host).contains(.agentEnvironments),
                inWorkingSection: section.id == LeoSidebarLayout.workingSectionID,
                unreadCount: unread.count(for: row.id)
            )
            .listRowInsets(LeoDispatchRowMetrics.agentRowInsets)
            .tag(Optional(LeoSidebarItemID.agent(row.id)))
            .id(LeoSidebarItemID.agent(row.id))
            // Its live dispatches (B-257), right under it; they follow the
            // row's filter and collapse. Untagged (never selected) unless
            // the daemon can attach to one (B-266).
            let dispatches = model.visibleDispatchRows(for: row)
            ForEach(dispatches) { item in
                dispatchRow(item, under: row, endsGroup: item.id == dispatches.last?.id)
                    .listRowInsets(LeoDispatchRowMetrics.listRowInsets)
            }
        }
    }

    @ViewBuilder private func dispatchRow(_ item: LeoDispatchRowItem, under row: LeoAgentRow, endsGroup: Bool) -> some View {
        let ref = LeoDispatchRef(host: row.host, id: item.id)
        let disclosure = item.hasChildren
            ? LeoDispatchRowView.Disclosure(isCollapsed: item.isCollapsed) { model.toggleDispatchCollapsed(ref) }
            : nil
        if model.isDispatchSelectable(item.node.dispatch, host: row.host) {
            LeoDispatchRowView(
                node: item.node,
                host: row.host,
                click: { model.dispatchClicked(ref, modifierFlags: $0, clickCount: $1, from: windowID) },
                disclosure: disclosure,
                endsGroup: endsGroup,
                isSelected: LeoSidebarSelection.current(model: model, terminals: terminals) == .dispatch(ref)
            )
            .tag(Optional(LeoSidebarItemID.dispatch(ref)))
            .id(LeoSidebarItemID.dispatch(ref))
        } else if model.isDispatchClickable(item.node.dispatch, host: row.host) {
            // Viewed in its caller's own tmux session (B-271): a click
            // brings that window forward and goes to the caller; untagged,
            // so never selected.
            LeoDispatchRowView(
                node: item.node,
                host: row.host,
                click: { model.dispatchClicked(ref, modifierFlags: $0, clickCount: $1, from: windowID) },
                isSelectable: false,
                disclosure: disclosure,
                endsGroup: endsGroup
            )
        } else {
            LeoDispatchRowView(node: item.node, host: row.host, disclosure: disclosure, endsGroup: endsGroup)
        }
    }

    private func searchEscape() {
        switch model.searchEscape() {
        case .cleared: break
        case .leaveField: searchField.focusTerminal()
        }
    }
}

/// Shown while Leo runs outside /Applications and managed features are off.
struct LeoAppLocationBannerView: View {
    let banner: LeoAppLocationBanner
    let move: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title).font(.callout.weight(.semibold))
                Text(banner.detail).font(.caption).foregroundStyle(.secondary)
                Button(banner.actionTitle, action: move).controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.title)
    }
}

/// B5: the local managed daemon's state, with its actions (takeover offer,
/// Login Items approval, move back, retry).
struct LeoManagedBannerView: View {
    let banner: LeoManagedBanner
    let perform: (LeoManagedBannerAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "gearshape.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.title).font(.callout.weight(.semibold))
                Text(banner.detail).font(.caption).foregroundStyle(.secondary)
                if banner.actions.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        ForEach(banner.actions, id: \.title) { action in
                            Button(action.title) { perform(action) }.controlSize(.small)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.title)
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
