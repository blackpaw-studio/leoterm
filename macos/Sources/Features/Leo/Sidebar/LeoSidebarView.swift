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
    /// Bumped by Agents ▸ Find Agent…; each change focuses the search field.
    let searchFocusRequest: Int
    @ObservedObject private var hostSelection: LeoHostSelection
    @State private var showingSpawn = false
    @State private var searchField = LeoSidebarSearchFieldHandle()
    @State private var hostsSheetModel: LeoHostsSheetModel?

    init(model: LeoSidebarModel, windowID: LeoWindowID, actions: LeoAgentActions, searchFocusRequest: Int = 0) {
        self.model = model
        self.windowID = windowID
        self.actions = actions
        self.searchFocusRequest = searchFocusRequest
        _hostSelection = ObservedObject(wrappedValue: actions.hostSelection)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Agents").font(.headline)
                Spacer()
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

            content
            if let panelError {
                Text(panelError).font(.caption).foregroundStyle(Color(nsColor: .systemRed))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onChange(of: searchFocusRequest) { _ in searchField.focus() }
        #if DEBUG
        .onAppear { LeoLaunchTiming.mark("sidebarAppeared", "connectivity=\(model.snapshot.connectivity) rows=\(model.snapshot.rows.count)") }
        #endif
        .sheet(isPresented: $showingSpawn) {
            SpawnAgentSheet(model: model, actions: actions) { row, disposition in
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

    @ViewBuilder private var content: some View {
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
        case .connected:
            if model.snapshot.rows.isEmpty {
                stateView {
                    Text("No Agents").font(.headline)
                    Text("Spawn an agent to start working with it from this window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Agent…") { showingSpawn = true }
                }
            } else if model.showsNoMatches {
                stateView { Text("No matches") }
            } else {
                agentList
            }
        case .disconnected:
            // The banner above says what happened and offers Retry; the
            // rows stay, dimmed and inert, until a Retry lands a fresh list.
            if model.snapshot.rows.isEmpty {
                stateView {
                    if hostSelection.selected == .local {
                        Button("Start daemon") { model.startDaemonRequested() }
                    }
                }
            } else if model.showsNoMatches {
                stateView { Text("No matches") }
            } else {
                agentList
                    .disabled(true)
                    .opacity(Self.inertOpacity)
                    .accessibilityHint("Disconnected")
            }
        }
    }

    /// How far a disconnected sidebar's stale rows are dimmed.
    private static let inertOpacity = 0.45

    private var agentList: some View {
        // Selection is required (`SelectionValue` is the optional ID
        // itself, so each row's tag is `Optional(row.id)`): the table
        // then never toggles the selected row off on ⌘-click, which here
        // opens a new tab (B-047, B-048). `nil` still shows no selection.
        List<LeoAgentRow.ID?, _>(selection: Binding(get: { model.selection }, set: { model.userSelected($0) })) {
            ForEach(model.sections) { section in
                Section(header: sectionHeader(section)) {
                    ForEach(section.isCollapsed ? [] : section.rows) { row in
                        LeoAgentRowView(
                            row: row,
                            isSelected: model.selection == row.id,
                            attach: { row, disposition in model.requestAttach(row, from: windowID, disposition: disposition) },
                            click: { model.rowClicked(row, modifierFlags: $0, clickCount: $1, from: windowID) },
                            actions: actions,
                            error: model.rowErrors[row.id],
                            errorCode: model.rowErrorCodes[row.id],
                            nameHighlights: model.searchHighlights(for: row),
                            isPinned: model.isPinned(row.id),
                            togglePin: { model.togglePin(row.id) },
                            pendingSurfacedFiles: model.pendingSurfacedFiles(for: row),
                            openSurfacedFile: { model.openSurfacedFile($0, for: row) }
                        )
                        .tag(Optional(row.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay(alignment: .bottomTrailing) {
            // A key equivalent, so it sees Return before the search
            // field does; there Return means the top match instead.
            // Both are a click on a row (B-049): the top match, or the
            // selection. Arrow keys only move the selection.
            Button("") { searchField.hasFocus ? model.searchSubmit(from: windowID) : model.activateSelection(from: windowID) }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
                .disabled(model.actionableSelection == nil)
                .accessibilityHidden(true)
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
