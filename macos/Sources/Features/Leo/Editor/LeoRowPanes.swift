import Combine
import Foundation

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

/// One row's editor pane and workspace browser. The browser opens files in
/// this row's editor, never another's.
@MainActor final class LeoRowPane {
    let editor: LeoEditorPaneModel
    let browser: LeoWorkspaceBrowserModel

    init(editor: LeoEditorPaneModel, browser: LeoWorkspaceBrowserModel) {
        self.editor = editor
        self.browser = browser
    }

    convenience init(makeAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess) {
        let editor = LeoEditorPaneModel(makeAccess: makeAccess)
        self.init(editor: editor, browser: LeoWorkspaceBrowserModel(makeAccess: makeAccess, openFile: { try await editor.open($0) }))
    }

    var isOpen: Bool { editor.isOpen || browser.isOpen }
    var hasUnsavedEdits: Bool { LeoUnsavedEditorsGate.hasUnsavedEdits(editor) }

    /// Drops the document without asking and closes the browser, releasing
    /// both file accesses (for a remote host, their `sftp` processes).
    func release() async {
        await browser.close()
        await editor.release()
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

    init(makeAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess, confirm: @escaping Confirm) {
        self.makeAccess = makeAccess
        self.confirm = confirm
        let startScreen = LeoRowPane(makeAccess: makeAccess)
        active = startScreen
        insert(startScreen, for: .startScreen)
    }

    /// Every pane, the one on screen first, then the rest as made, then
    /// those whose rows went.
    var all: [LeoRowPane] {
        let keyed = order.compactMap { panes[$0] }
        return [active] + (keyed + orphans).filter { $0 !== active }
    }

    var allEditors: [LeoEditorPaneModel] { all.map(\.editor) }
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

    /// The window now shows `key`'s row: its pane goes on screen.
    func activate(_ key: LeoRowKey) {
        let pane = pane(for: key)
        if activeKey != key { activeKey = key }
        if active !== pane { active = pane }
    }

    /// Closes `key`'s pane, asking first when it has unsaved edits. `false`
    /// when the user cancelled (or Save failed): the pane stays.
    func close(_ key: LeoRowKey) async -> Bool {
        guard let pane = panes[key] else { return true }
        guard await pane.editor.close() else { return false }
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

    private func insert(_ pane: LeoRowPane, for key: LeoRowKey) {
        panes[key] = pane
        order.append(key)
        pane.editor.confirmUnsaved = { [weak self, weak pane] document in
            guard let self else { return .cancel }
            let isOnScreen = pane === active
            return await confirm(document, isOnScreen ? nil : rowName(self.key(holding: pane) ?? .startScreen))
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
