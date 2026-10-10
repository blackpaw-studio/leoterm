import Combine
import Foundation

/// Who an open is for (B-273): the user's own action, or a file an agent
/// surfaced, which opens behind whatever the user is doing.
enum LeoEditorOpenMode: Sendable {
    /// Selects its tab and asks for focus.
    case user
    /// Never asks for focus, and selects its tab only while nothing the
    /// user did since -- or a newer open -- has taken the selection.
    case background
}

/// A row's editor pane as tabs (B-273): one `LeoEditorPaneModel` per open
/// file, so each keeps its own close, wait and abandon machinery (D-454),
/// and the gate sees every tab (`tabs`). Every open adds a tab or selects
/// the file's own; nothing replaces a document. A tab whose document goes
/// (closed, abandoned, released) drops out on its own, the selection
/// moving to its right-hand neighbour, else its left.
@MainActor final class LeoEditorTabs: ObservableObject {
    /// Tabs past this close the least recently selected clean one.
    static let tabLimit = LeoEditorPaneModel.recentsLimit

    @Published private(set) var tabs: [LeoEditorPaneModel] = []
    @Published private(set) var selected: LeoEditorPaneModel?
    /// Most recent first, the open files included.
    @Published private(set) var recents: [LeoEditorFileID] = []
    /// Bumped when the user's own open or selection wants the selected
    /// tab's text focused; a background open never bumps it.
    @Published private(set) var focusRequest = 0
    /// Presents the unsaved-changes prompt for any tab, once that tab is
    /// selected. Until set, never discards.
    var confirmUnsaved: @MainActor (LeoEditorDocument) async -> LeoUnsavedChangesChoice = { _ in .cancel }

    private let makeAccess: @MainActor (LeoHostID) throws -> any LeoFileAccess
    private let policy: LeoEditorContentPolicy
    /// Each user selection bumps it: a background open asked for before
    /// then leaves the selection alone.
    private var userSelectionEpoch = 0
    private var requestSerial = 0
    /// The request whose tab last took the selection: an older background
    /// open finishing later doesn't take it back.
    private var selectedSerial = 0
    /// When each tab was last selected (or added), for the tab limit.
    private var touched: [ObjectIdentifier: Int] = [:]
    private var touchClock = 0
    private var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var pendingShown: [@MainActor () -> Void] = []
    private var isReleased = false

    init(makeAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess, policy: LeoEditorContentPolicy = .default) {
        self.makeAccess = makeAccess
        self.policy = policy
    }

    var isOpen: Bool { !tabs.isEmpty }
    /// The selected tab's document.
    var document: LeoEditorDocument? { selected?.document }
    var hasUnsavedEdits: Bool { tabs.contains(where: LeoUnsavedEditorsGate.hasUnsavedEdits) }

    func tab(for fileID: LeoEditorFileID) -> LeoEditorPaneModel? {
        tabs.first { $0.document?.fileID == fileID }
    }

    // MARK: - Opening

    /// Opens `fileID` in a new tab, or selects (and reveals in) the tab
    /// that has it already (`.alreadyOpen`, its edits kept). The file is
    /// read before a tab is added, so one that can't open (the error is
    /// thrown) adds nothing. See `LeoEditorPaneModel.open` for `access`,
    /// `readDeadline` and `isStillWanted`.
    @discardableResult
    func open(
        _ fileID: LeoEditorFileID, line: Int? = nil, column: Int? = nil, mode: LeoEditorOpenMode = .user,
        access: (@MainActor (LeoHostID) throws -> any LeoFileAccess)? = nil,
        readDeadline: LeoReadDeadline? = nil,
        isStillWanted: @escaping @MainActor () -> Bool = { true }
    ) async throws -> LeoEditorOpenOutcome {
        requestSerial += 1
        let request = Request(serial: requestSerial, epoch: userSelectionEpoch, mode: mode)
        let wanted: @MainActor () -> Bool = { [weak self] in self?.isReleased == false && isStillWanted() }
        if let existing = tab(for: fileID) {
            let outcome = try await existing.open(fileID, line: line, column: column, isStillWanted: wanted)
            guard outcome == .alreadyOpen, contains(existing) else { return outcome }
            commitSelection(of: existing, for: request, fileID: fileID)
            return .alreadyOpen
        }
        let tab = LeoEditorPaneModel(makeAccess: makeAccess, policy: policy)
        let outcome = try await tab.open(
            fileID, line: line, column: column, access: access, readDeadline: readDeadline, isStillWanted: wanted
        )
        guard outcome == .opened else { return outcome }
        guard wanted() else {
            await tab.release()
            return .cancelled
        }
        // Another open of the same file landed while this one read: that
        // tab stays, with whatever was typed in it.
        if let existing = self.tab(for: fileID) {
            await tab.release()
            commitSelection(of: existing, for: request, fileID: fileID)
            return .alreadyOpen
        }
        insert(tab)
        commitSelection(of: tab, for: request, fileID: fileID)
        await closeOverLimit()
        return .opened
    }

    /// What `~` means on `host`.
    func homeDirectory(on host: LeoHostID) async throws -> String {
        try await withAccess(on: host) { try await $0.homeDirectory() }
    }

    /// `fileID`'s stat on its host (following symlinks).
    func stat(_ fileID: LeoEditorFileID) async throws -> LeoFileStat {
        try await withAccess(on: fileID.host) { try await $0.stat(fileID.path) }
    }

    // MARK: - Selecting

    /// The user picked `tab` (its strip button, the recents pop-up):
    /// `focusing` asks for its text to take focus.
    func select(_ tab: LeoEditorPaneModel, focusing: Bool = true) {
        guard contains(tab) else { return }
        userSelectionEpoch += 1
        setSelected(tab)
        if let fileID = tab.document?.fileID { remember(fileID) }
        if focusing { focusRequest += 1 }
    }

    /// The next tab to the right, wrapping. Focus stays where it is.
    func selectNext() { selectNeighbour(by: 1) }

    /// The next tab to the left, wrapping. Focus stays where it is.
    func selectPrevious() { selectNeighbour(by: -1) }

    // MARK: - Closing

    /// Closes `tab`, asking first when it has unsaved edits. `false` when
    /// the user cancelled (or Save failed): the tab stays.
    @discardableResult
    func closeTab(_ tab: LeoEditorPaneModel) async -> Bool {
        guard contains(tab) else { return true }
        return await tab.close()
    }

    /// Closes the selected tab, asking first. `false` on Cancel.
    @discardableResult
    func closeSelected() async -> Bool {
        guard let selected else { return true }
        return await closeTab(selected)
    }

    /// Closes every tab in order, asking about each one with unsaved edits
    /// (selected in turn). The first Cancel stops: the tabs already closed
    /// stay closed, the rest stay open.
    @discardableResult
    func closeAll() async -> Bool {
        for tab in tabs where contains(tab) {
            guard await tab.close() else { return false }
        }
        return true
    }

    /// The pane is gone: every tab drops its document without asking (its
    /// close asked first) and lets go of its file access. Opens still in
    /// flight add nothing.
    func release() async {
        isReleased = true
        pendingShown = []
        for tab in tabs { await tab.release() }
    }

    // MARK: - Shown

    /// Runs `action` once this pane is next on screen in a visible window
    /// (`markShown`), e.g. to mark a background-opened surfaced file seen.
    func whenShown(_ action: @escaping @MainActor () -> Void) {
        guard !isReleased else { return }
        pendingShown.append(action)
    }

    /// The pane is on screen in a visible window.
    func markShown() {
        let actions = pendingShown
        pendingShown = []
        actions.forEach { $0() }
    }

    // MARK: - Helpers

    private struct Request {
        let serial: Int
        let epoch: Int
        let mode: LeoEditorOpenMode
    }

    private func contains(_ tab: LeoEditorPaneModel) -> Bool {
        tabs.contains { $0 === tab }
    }

    private func commitSelection(of tab: LeoEditorPaneModel, for request: Request, fileID: LeoEditorFileID) {
        remember(fileID)
        switch request.mode {
        case .user:
            userSelectionEpoch += 1
            selectedSerial = max(selectedSerial, request.serial)
            setSelected(tab)
            focusRequest += 1
        case .background:
            let isUntouched = request.epoch == userSelectionEpoch && request.serial > selectedSerial
            guard selected == nil || isUntouched else { return }
            selectedSerial = request.serial
            setSelected(tab)
        }
    }

    private func setSelected(_ tab: LeoEditorPaneModel) {
        touch(tab)
        if selected !== tab { selected = tab }
    }

    private func selectNeighbour(by offset: Int) {
        guard tabs.count > 1, let selected, let index = tabs.firstIndex(where: { $0 === selected }) else { return }
        let next = tabs[(index + offset + tabs.count) % tabs.count]
        select(next, focusing: false)
    }

    private func insert(_ tab: LeoEditorPaneModel) {
        let id = ObjectIdentifier(tab)
        tab.confirmUnsaved = { [weak self, weak tab] document in
            guard let self else { return .cancel }
            // The tab asked about is the one shown.
            if let tab, contains(tab) { setSelected(tab) }
            return await confirmUnsaved(document)
        }
        // Synchronous (no `receive(on:)`): a tab whose document went is
        // gone before anything can look it up again.
        subscriptions[id] = tab.$document.dropFirst().sink { [weak self, weak tab] document in
            guard document == nil else { return }
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                self.remove(tab)
            }
        }
        touch(tab)
        tabs.append(tab)
    }

    private func remove(_ tab: LeoEditorPaneModel) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let id = ObjectIdentifier(tab)
        subscriptions[id] = nil
        touched[id] = nil
        var remaining = tabs
        remaining.remove(at: index)
        tabs = remaining
        guard selected === tab else { return }
        let neighbour = remaining.indices.contains(index) ? remaining[index] : remaining.last
        if let neighbour { touch(neighbour) }
        selected = neighbour
    }

    private func touch(_ tab: LeoEditorPaneModel) {
        touchClock += 1
        touched[ObjectIdentifier(tab)] = touchClock
    }

    /// Past the limit, the least recently selected clean tab that isn't
    /// selected closes (silently: it has nothing to ask about). A tab with
    /// unsaved edits is never closed for room.
    private func closeOverLimit() async {
        while tabs.count > Self.tabLimit {
            let candidates = tabs.filter { $0 !== selected && !LeoUnsavedEditorsGate.hasUnsavedEdits($0) && !$0.isWaitingToClose }
            let count = tabs.count
            guard let oldest = candidates.min(by: { stamp($0) < stamp($1) }), await oldest.close(), tabs.count < count else { return }
        }
    }

    private func stamp(_ tab: LeoEditorPaneModel) -> Int {
        touched[ObjectIdentifier(tab)] ?? 0
    }

    private func remember(_ fileID: LeoEditorFileID) {
        recents = Array(([fileID] + recents.filter { $0 != fileID }).prefix(LeoEditorPaneModel.recentsLimit))
    }

    private func withAccess<T>(on host: LeoHostID, _ body: (any LeoFileAccess) async throws -> T) async throws -> T {
        let access = try makeAccess(host)
        do {
            let value = try await body(access)
            await access.close()
            return value
        } catch {
            await access.close()
            throw error
        }
    }
}
