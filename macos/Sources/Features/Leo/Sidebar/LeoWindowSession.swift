import Combine
import AppKit
import Foundation

struct LeoWindowVisibilityState: Equatable {
    enum Event {
        case occlusionChanged(isVisible: Bool)
        case miniaturized
        case deminiaturized
    }

    private(set) var isOccluded = false
    private(set) var isMiniaturized = false

    mutating func reduce(_ event: Event) {
        switch event {
        case .occlusionChanged(let isVisible): isOccluded = !isVisible
        case .miniaturized: isMiniaturized = true
        case .deminiaturized: isMiniaturized = false
        }
    }
}

@MainActor final class LeoWindowSession: ObservableObject {
    /// The sidebar's width, one value shared by every window (D-144).
    static let sidebarWidthKey = "leo.sidebarWidth"
    let id: LeoWindowID
    @Published var isSidebarVisible: Bool { didSet { changed() } }
    /// True while this window's agent palette is on screen. The sidebar can
    /// be hidden (the default) and still need live agent data for the
    /// palette, so pollability considers both -- see `isPollable`. Set by
    /// `LeoPickerPresentation` via `setPickerPresented(_:)`.
    @Published private(set) var isPickerPresented = false { didSet { changed() } }
    @Published private(set) var preferredWidth: CGFloat
    /// Bumped by Agents ▸ Find Agent… (B-009); the sidebar's search field
    /// takes focus whenever it changes.
    @Published private(set) var searchFocusRequest = 0
    /// Bumped by Agents ▸ Message Agent (B-262); the control bar's prompt
    /// field takes focus whenever it changes.
    @Published private(set) var controlFocusRequest = 0
    /// The control bar's prompt field, for focus in and back out.
    let controlPrompt = LeoControlPromptFieldHandle()
    @Published var windowIsOccluded = false { didSet { changed(); markShownIfVisible() } }
    @Published var windowIsMiniaturized = false { didSet { changed(); markShownIfVisible() } }
    var displayedWidth: CGFloat { min(max(preferredWidth, 200), 420) }
    /// Opens the agent picker for this window's placeholder. Wired by
    /// `LeoRuntime.makeWindowSession(for:)`; a no-op until then (e.g. in
    /// tests that construct a session directly).
    var openPicker: (UUID?) -> Void = { _ in }
    @Published private(set) var placeholderSurfaceIDs: Set<UUID> = []
    /// Fired once, synchronously, from `NSWindow.willCloseNotification` --
    /// lets `LeoRuntime` tear down this window's router state and palette
    /// presentation immediately instead of waiting for the registry's next
    /// opportunistic reconciliation (`report()`, only triggered by some
    /// *other* session's state change or a new `makeSession` call).
    var onWindowWillClose: () -> Void = {}
    /// Each row's editor and browser in this window (B-274); the one on
    /// screen belongs to the row the window shows.
    let panes: LeoRowPanes
    /// The editor pane on screen (B-004), beside the terminal: its tabs (B-273).
    var editor: LeoEditorTabs { panes.active.tabs }
    /// Its view, once the window's split view has built it (focus moves).
    var editorPane: LeoEditorTabsViewController? { editorContainer?.activeChild as? LeoEditorTabsViewController }
    /// The workspace browser on screen (B-005), on the editor's leading
    /// edge; it opens files in its own row's editor.
    var browser: LeoWorkspaceBrowserModel { panes.active.browser }
    var browserPane: LeoWorkspaceBrowserViewController? { browserContainer?.activeChild as? LeoWorkspaceBrowserViewController }
    /// The split items holding them, once the window's split view is built.
    weak var editorContainer: LeoRowPaneContainerViewController?
    weak var browserContainer: LeoRowPaneContainerViewController?

    func adopt(_ container: LeoRowPaneContainerViewController) {
        switch container.role {
        case .editor: editorContainer = container
        case .browser: browserContainer = container
        }
    }
    /// The window's plain shells, its sidebar's Terminals section (B-057).
    let terminals = LeoWindowTerminals()

    /// Whether showing the sidebar now would take the terminal under its
    /// floor beside a side pane (D-058, D-059).
    var showingSidebarSqueezesTerminal: Bool {
        split?.sidebarSqueezesTerminal(atWidth: displayedWidth) ?? false
    }

    /// Return To Default Size gives a shown sidebar its stored width back,
    /// even one the launch clamped (D-361). Nothing is persisted.
    func restoreStoredSidebarWidth() {
        guard isSidebarVisible else { return }
        split?.restoreSidebarWidth(displayedWidth)
    }

    /// The window's split, found through the panes it built.
    private var split: LeoSplitViewController? {
        (browserContainer?.parent ?? editorContainer?.parent) as? LeoSplitViewController
    }

    private let defaults: UserDefaults
    private let onPollabilityChanged: () -> Void
    private(set) weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var visibility = LeoWindowVisibilityState()
    private var activePaneSubscription: AnyCancellable?

    init(
        id: LeoWindowID = LeoWindowID(),
        window: NSWindow? = nil,
        defaults: UserDefaults = .standard,
        makeFileAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess = LeoWindowSession.noFileAccess,
        onPollabilityChanged: @escaping () -> Void = {}
    ) {
        self.id = id
        self.defaults = defaults
        let windowBox = LeoWeakWindow(window)
        panes = LeoRowPanes(makeAccess: makeFileAccess) { document, row in
            guard let window = windowBox.window else { return .cancel }
            return await LeoEditorAlerts.confirmUnsavedChanges(to: document.displayName, in: row, on: window)
        }
        self.onPollabilityChanged = onPollabilityChanged
        self.window = window
        // Fresh installs start with the sidebar hidden -- a persisted user
        // choice (the key is present, either true or false) always wins.
        isSidebarVisible = defaults.object(forKey: "leo.sidebarVisible") as? Bool ?? false
        preferredWidth = (defaults.object(forKey: Self.sidebarWidthKey) as? NSNumber).map { CGFloat($0.doubleValue) } ?? 260
        terminals.rowRemoved = { [weak panes] id in panes?.rowRemoved(.terminal(id)) }
        terminals.rowReplaced = { [weak panes] old, new in panes?.rekey(.terminal(old), to: .terminal(new)) }
        panes.rowName = { [weak terminals] key in
            switch key {
            case .agent(_, let name, _): name
            case .terminal(let id): terminals?.rows.first { $0.id == id }?.displayTitle
            case .startScreen: nil
            }
        }
        observeWindow()
        // `@Published` sends before it stores: the pane is the new value.
        activePaneSubscription = panes.$active.sink { [weak self] pane in
            MainActor.assumeIsolated {
                guard let self, self.isWindowVisible else { return }
                pane.tabs.markShown()
            }
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Until the runtime wires the selected host's file access in.
    static func noFileAccess(_ host: LeoHostID) throws -> any LeoFileAccess {
        throw LeoFileAccessError.unavailable(reason: "Leo isn’t connected to \(host.displayName)")
    }

    var isPollable: Bool { (isSidebarVisible || isPickerPresented) && !windowIsOccluded && !windowIsMiniaturized }

    func setSidebarVisible(_ visible: Bool) {
        isSidebarVisible = visible
        defaults.set(visible, forKey: "leo.sidebarVisible")
    }

    /// Agents ▸ Find Agent…: show the sidebar if hidden and focus its filter.
    func requestSearchFocus() {
        if !isSidebarVisible { setSidebarVisible(true) }
        searchFocusRequest += 1
    }

    /// Agents ▸ Message Agent: focus the control bar's prompt field.
    func requestControlFocus() { controlFocusRequest += 1 }

    /// Called by `LeoPickerPresentation` when its panel is shown/dismissed.
    /// Not persisted -- unlike sidebar visibility, this reflects transient
    /// palette-open state, not a user preference.
    func setPickerPresented(_ presented: Bool) {
        isPickerPresented = presented
    }

    func rebirthPlaceholder(surfaceID: UUID) { placeholderSurfaceIDs.insert(surfaceID) }
    func fillPlaceholder(surfaceID: UUID) { placeholderSurfaceIDs.remove(surfaceID) }

    func setPreferredWidth(_ width: CGFloat) {
        preferredWidth = width
        defaults.set(Double(width), forKey: Self.sidebarWidthKey)
    }

    func openPicker(surfaceID: UUID?) { openPicker(surfaceID) }

    private func observeWindow() {
        guard let window else { return }
        apply(.occlusionChanged(isVisible: window.occlusionState.contains(.visible)))
        if window.isMiniaturized { apply(.miniaturized) }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.apply(.occlusionChanged(isVisible: window.occlusionState.contains(.visible))) }
            },
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(.miniaturized) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowWillClose() }
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(.deminiaturized) }
            },
        ]
    }

    private func windowWillClose() {
        onWindowWillClose()
        let panes = panes
        Task { await panes.releaseAll() }
    }

    private func apply(_ event: LeoWindowVisibilityState.Event) {
        visibility.reduce(event)
        windowIsOccluded = visibility.isOccluded
        windowIsMiniaturized = visibility.isMiniaturized
    }

    private func changed() { onPollabilityChanged() }

    /// The window is on screen: neither miniaturized nor fully covered.
    var isWindowVisible: Bool { !windowIsOccluded && !windowIsMiniaturized }

    /// B-273: the row on screen, in a visible window, is viewed -- what
    /// its pane waits on (`LeoEditorTabs.whenShown`) runs, e.g. marking a
    /// background-opened surfaced file seen.
    func markShownIfVisible() {
        guard isWindowVisible else { return }
        panes.active.tabs.markShown()
    }
}

/// The session's window, held weakly for the panes' prompts.
@MainActor private final class LeoWeakWindow {
    weak var window: NSWindow?
    init(_ window: NSWindow?) { self.window = window }
}

@MainActor final class LeoWindowSessionRegistry {
    private final class Entry {
        weak var session: LeoWindowSession?
        weak var controller: TerminalController?
        init(_ session: LeoWindowSession, controller: TerminalController?) { self.session = session; self.controller = controller }
    }
    private var entries: [LeoWindowID: Entry] = [:]
    var pollabilityChanged: (Bool) -> Void = { _ in }
    /// Fired for a window id the next time `report()` runs (a session
    /// change, or a new `makeSession` call) after that id's session has
    /// deallocated. Not proactive -- there is no deinit hook on
    /// `LeoWindowSession` -- but it's reconciled on the same cadence as
    /// `hasPollableSidebar` already is.
    var onUnregistered: (LeoWindowID) -> Void = { _ in }

    func makeSession(
        window: NSWindow? = nil,
        controller: TerminalController? = nil,
        defaults: UserDefaults = .standard,
        makeFileAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess = LeoWindowSession.noFileAccess
    ) -> LeoWindowSession {
        let session = LeoWindowSession(window: window, defaults: defaults, makeFileAccess: makeFileAccess) { [weak self] in self?.report() }
        entries[session.id] = Entry(session, controller: controller)
        report()
        return session
    }

    var hasPollableSidebar: Bool {
        entries.values.contains { $0.session?.isPollable == true }
    }

    func controller(for id: LeoWindowID) -> TerminalController? { entries[id]?.controller }

    func session(for id: LeoWindowID) -> LeoWindowSession? { entries[id]?.session }

    var sessions: [LeoWindowSession] { entries.values.compactMap(\.session) }

    private func report() {
        let before = entries.keys
        entries = entries.filter { $0.value.session != nil }
        for id in before where entries[id] == nil { onUnregistered(id) }
        pollabilityChanged(hasPollableSidebar)
    }
}
