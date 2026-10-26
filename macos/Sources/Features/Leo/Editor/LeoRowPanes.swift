import Combine
import Foundation
import LeoKit

/// The sidebar row a window's editor and browser belong to (B-274): an
/// agent (by host, name and dispatch, not by what it last reported), a
/// terminal row's shell, or the window's start screen.
enum LeoRowKey: Hashable, Sendable {
    case agent(host: LeoHostID, name: String, dispatchID: String?)
    case terminal(UUID)
    case startScreen

    static func agent(_ identity: LeoAgentIdentity) -> Self {
        .agent(host: identity.host, name: identity.name, dispatchID: identity.dispatchID)
    }

    var host: LeoHostID? {
        guard case .agent(let host, _, _) = self else { return nil }
        return host
    }
}

/// One row's editor tabs, workspace browser and, while its agent has one,
/// the agent's web browser. The workspace browser opens files in this row's
/// editor, never another's. The editor pane shows one of two contents: the
/// editor tabs, or the agent browser (`content`).
@MainActor final class LeoRowPane: ObservableObject {
    enum Content: Equatable {
        case editor
        case agentBrowser
    }

    let tabs: LeoEditorTabs
    let browser: LeoWorkspaceBrowserModel
    /// The row's agent's browser while it has one.
    @Published private(set) var agentBrowser: (any LeoAgentBrowserPaneSource)?
    /// Asks whoever owns the browsers to close this row's (wired by `LeoRowPanes`).
    var requestCloseAgentBrowser: () -> Void = {}
    /// The user (or the lack of open files) put the browser in front of the editor.
    @Published private var showsAgentBrowser = false
    private var tabsSubscription: AnyCancellable?

    init(tabs: LeoEditorTabs, browser: LeoWorkspaceBrowserModel) {
        self.tabs = tabs
        self.browser = browser
        // The last file closing leaves the browser as the pane's content, and
        // it stays there when a file opens behind it.
        tabsSubscription = tabs.$tabs.sink { [weak self] tabs in
            if tabs.isEmpty, self?.agentBrowser != nil { self?.showsAgentBrowser = true }
        }
    }

    convenience init(makeAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess) {
        let tabs = LeoEditorTabs(makeAccess: makeAccess)
        self.init(tabs: tabs, browser: LeoWorkspaceBrowserModel(makeAccess: makeAccess, openFile: { try await tabs.open($0) }))
    }

    var isAgentBrowserOpen: Bool { agentBrowser != nil }
    var content: Content { agentBrowser != nil && showsAgentBrowser ? .agentBrowser : .editor }

    /// The agent started a browser. It comes to the front only when no file
    /// is open; otherwise it opens behind what the user is editing, as a file
    /// an agent surfaces does.
    func attachAgentBrowser(_ source: any LeoAgentBrowserPaneSource) {
        guard agentBrowser !== source else { return }
        agentBrowser = source
        showsAgentBrowser = tabs.tabs.isEmpty
    }

    func detachAgentBrowser() {
        guard agentBrowser != nil else { return }
        agentBrowser = nil
        showsAgentBrowser = false
    }

    func showAgentBrowser() {
        if agentBrowser != nil { showsAgentBrowser = true }
    }

    func showEditor() {
        showsAgentBrowser = false
    }

    /// Closes the browser (the Browser tab's close, the toolbar's); its data store stays.
    func closeAgentBrowser() {
        requestCloseAgentBrowser()
        detachAgentBrowser()
    }

    var isOpen: Bool { tabs.isOpen || browser.isOpen }
    /// Any of its tabs has unsaved edits.
    var hasUnsavedEdits: Bool { tabs.hasUnsavedEdits }

    /// Drops every tab's document without asking and closes the browser,
    /// releasing their file accesses (for a remote host, `sftp` processes).
    func release() async {
        // The tabs first: from here no open in flight adds one.
        await tabs.release()
        await browser.close()
    }
}

/// A window's panes, one per row it has shown one for (B-274). The pane on
/// screen is the row the window last navigated to (`activate`); the others
/// keep their document, edits, scroll and browser expansion until their
/// row goes or the window closes. Independent of the live pool: evicting
/// a row's surface never touches its pane.
///
/// Nothing with unsaved edits goes without asking: `close` asks; a row
/// that goes without asking (its shell exited) keeps a dirty pane -- on the
/// start screen when it was on screen (`isStartScreenOrphan`), otherwise
/// held for window close or quit to ask about (`allEditors`).
@MainActor final class LeoRowPanes: ObservableObject {
    /// Presents the unsaved-changes prompt for `document`; `row` names its
    /// row when that pane isn't the one on screen.
    typealias Confirm = @MainActor (_ document: LeoEditorDocument, _ row: String?) async -> LeoUnsavedChangesChoice

    @Published private(set) var activeKey: LeoRowKey = .startScreen
    /// The pane on screen. Kept while its row goes, until the next row shows.
    @Published private(set) var active: LeoRowPane
    /// The start screen shows a pane its row left with unsaved edits:
    /// leaving it asks first (`leaveOrphanedStartScreen`).
    @Published private(set) var isStartScreenOrphan = false
    /// What a row is called in a prompt about its pane (wired by the session).
    var rowName: (LeoRowKey) -> String? = { _ in nil }

    private var panes: [LeoRowKey: LeoRowPane] = [:]
    /// Rows in the order their panes were made, for a stable ask order.
    private var order: [LeoRowKey] = []
    /// Panes whose hidden rows went with unsaved edits.
    private var orphans: [LeoRowPane] = []
    private let makeAccess: @MainActor (LeoHostID) throws -> any LeoFileAccess
    private let confirm: Confirm
    /// Which agent browsers exist, for the rows' panes to show; nil for none.
    private let presence: (any LeoAgentBrowserPresence)?
    private var stopObservingPresence: (() -> Void)?

    init(
        makeAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess, confirm: @escaping Confirm,
        presence: (any LeoAgentBrowserPresence)? = nil
    ) {
        self.makeAccess = makeAccess
        self.confirm = confirm
        self.presence = presence
        let startScreen = LeoRowPane(makeAccess: makeAccess)
        active = startScreen
        insert(startScreen, for: .startScreen)
        observePresence()
    }

    /// One pane standing in for a window's (a split built around a given
    /// editor and browser): it keeps its own prompt.
    init(startScreen pane: LeoRowPane, presence: (any LeoAgentBrowserPresence)? = nil) {
        makeAccess = LeoWindowSession.noFileAccess
        confirm = { _, _ in .cancel }
        self.presence = presence
        active = pane
        insert(pane, for: .startScreen, installingPrompt: false)
        observePresence()
    }

    /// Every pane, the one on screen first, then the rest as made, then
    /// those whose rows went.
    var all: [LeoRowPane] {
        let keyed = order.compactMap { panes[$0] }
        return [active] + (keyed + orphans).filter { $0 !== active }
    }

    /// Every tab of every pane, for the gate.
    var allEditors: [LeoEditorPaneModel] { all.flatMap(\.tabs.tabs) }
    var hasUnsavedEdits: Bool { all.contains(where: \.hasUnsavedEdits) }
    var keys: [LeoRowKey] { order }

    func existingPane(for key: LeoRowKey) -> LeoRowPane? { panes[key] }

    /// `key`'s pane, made empty the first time it's asked for.
    func pane(for key: LeoRowKey) -> LeoRowPane {
        if let pane = panes[key] { return pane }
        let pane = LeoRowPane(makeAccess: makeAccess)
        insert(pane, for: key)
        return pane
    }

    /// The row's Open Browser: finds or makes `key`'s agent browser (on a
    /// blank page) and puts it in front in the row's pane. False for a row
    /// with no agent, or when this Mac can't run the browser.
    @discardableResult
    func openAgentBrowser(for key: LeoRowKey) -> Bool {
        guard let presence, let browserKey = key.agentBrowserKey, presence.openBrowser(for: browserKey) != nil else { return false }
        let pane = pane(for: key)
        syncAgentBrowser(of: pane, for: key)
        pane.showAgentBrowser()
        return true
    }

    /// The window now shows `key`'s row: its pane goes on screen.
    func activate(_ key: LeoRowKey) {
        let pane = pane(for: key)
        if activeKey != key { activeKey = key }
        if active !== pane { active = pane }
    }

    /// Closes `key`'s pane, asking first about each tab with unsaved
    /// edits. `false` when the user cancelled (or Save failed): the pane
    /// stays, with the tabs not yet closed.
    func close(_ key: LeoRowKey) async -> Bool {
        guard let pane = panes[key] else { return true }
        guard await pane.tabs.closeAll() else { return false }
        // Its row went (or was carried on) meanwhile: nothing left to do.
        guard panes[key] === pane else { return true }
        remove(key)
        await pane.release()
        return true
    }

    /// `key`'s row went without asking (its shell exited, its agent left):
    /// a clean pane closes; one with unsaved edits is kept -- on the start
    /// screen when it was on screen, otherwise until the window closes.
    func rowRemoved(_ key: LeoRowKey) {
        guard let pane = panes[key] else { return }
        guard pane.hasUnsavedEdits else {
            remove(key)
            Task { await pane.release() }
            return
        }
        guard key != .startScreen else { return }
        if pane === active {
            rekey(key, to: .startScreen)
            isStartScreenOrphan = true
        } else {
            remove(key)
            orphans.append(pane)
        }
    }

    /// `old`'s row carries on as `new`'s (B-082): its pane goes along, and
    /// a pane `new` already had goes as a removed row's does.
    func rekey(_ old: LeoRowKey, to new: LeoRowKey) {
        guard old != new, let pane = panes[old] else { return }
        if panes[new] != nil { rowRemoved(new) }
        remove(old)
        insert(pane, for: new)
        if activeKey == old { activeKey = new }
        syncAgentBrowser(of: pane, for: new)
    }

    /// `host`'s list, fetched while connected, no longer has these agents
    /// or dispatches (`isListed` says which it has): their panes go as a
    /// removed row's do. The row on screen keeps its pane until it's left.
    func pruneAgents(on host: LeoHostID, keeping isListed: (_ name: String, _ dispatchID: String?) -> Bool) {
        let gone = order.filter { key in
            guard case .agent(let keyHost, let name, let dispatchID) = key, keyHost == host, key != activeKey else { return false }
            return !isListed(name, dispatchID)
        }
        gone.forEach(rowRemoved)
    }

    /// Before the start screen is replaced: a pane its row left there with
    /// unsaved edits is closed, asking first. `false` on Cancel.
    func leaveOrphanedStartScreen() async -> Bool {
        guard isStartScreenOrphan else { return true }
        return await close(.startScreen)
    }

    /// The window is gone: every pane drops its document without asking
    /// (its closes asked first) and lets go of its file access.
    func releaseAll() async {
        let all = all
        panes = [:]
        order = []
        orphans = []
        isStartScreenOrphan = false
        for pane in all { await pane.release() }
    }

    // MARK: - Helpers

    private func insert(_ pane: LeoRowPane, for key: LeoRowKey, installingPrompt: Bool = true) {
        panes[key] = pane
        order.append(key)
        pane.requestCloseAgentBrowser = { [weak self, weak pane] in
            guard let self, let browserKey = self.key(holding: pane)?.agentBrowserKey else { return }
            presence?.closeBrowser(for: browserKey)
        }
        syncAgentBrowser(of: pane, for: key)
        guard installingPrompt else { return }
        pane.tabs.confirmUnsaved = { [weak self, weak pane] document in
            guard let self else { return .cancel }
            let isOnScreen = pane === active
            return await confirm(document, isOnScreen ? nil : rowName(self.key(holding: pane) ?? .startScreen))
        }
    }

    private func observePresence() {
        stopObservingPresence = presence?.observe { [weak self] change in
            guard let self else { return }
            let key: LeoAgentBrowserKey = switch change {
            case .opened(let key), .closed(let key): key
            }
            for (rowKey, pane) in panes where rowKey.agentBrowserKey == key { syncAgentBrowser(of: pane, for: rowKey) }
        }
    }

    /// `pane` shows its agent's browser while the presence has one.
    private func syncAgentBrowser(of pane: LeoRowPane, for key: LeoRowKey) {
        guard let presence, let browserKey = key.agentBrowserKey else { return }
        if let source = presence.browser(for: browserKey) {
            pane.attachAgentBrowser(source)
        } else {
            pane.detachAgentBrowser()
        }
    }

    private func remove(_ key: LeoRowKey) {
        panes[key] = nil
        order.removeAll { $0 == key }
        if key == .startScreen { isStartScreenOrphan = false }
    }

    private func key(holding pane: LeoRowPane?) -> LeoRowKey? {
        guard let pane else { return nil }
        return panes.first { $0.value === pane }?.key
    }
}
