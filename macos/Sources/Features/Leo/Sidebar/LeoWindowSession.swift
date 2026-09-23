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
    let id: LeoWindowID
    @Published var isSidebarVisible: Bool { didSet { changed() } }
    /// True while this window's agent palette is on screen. The sidebar can
    /// be hidden (the default) and still need live agent data for the
    /// palette, so pollability considers both -- see `isPollable`. Set by
    /// `LeoPickerPresentation` via `setPickerPresented(_:)`.
    @Published private(set) var isPickerPresented = false { didSet { changed() } }
    @Published private(set) var preferredWidth: CGFloat
    @Published var windowIsOccluded = false { didSet { changed() } }
    @Published var windowIsMiniaturized = false { didSet { changed() } }
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
    /// The window's editor pane (B-004): one per window, beside the terminal.
    let editor: LeoEditorPaneModel
    /// Its view, once the window's split view has built it (focus moves).
    weak var editorPane: LeoEditorPaneViewController?

    private let defaults: UserDefaults
    private let onPollabilityChanged: () -> Void
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var visibility = LeoWindowVisibilityState()

    init(
        id: LeoWindowID = LeoWindowID(),
        window: NSWindow? = nil,
        defaults: UserDefaults = .standard,
        makeFileAccess: @escaping @MainActor (LeoHostID) throws -> any LeoFileAccess = LeoWindowSession.noFileAccess,
        onPollabilityChanged: @escaping () -> Void = {}
    ) {
        self.id = id
        self.defaults = defaults
        editor = LeoEditorPaneModel(makeAccess: makeFileAccess)
        self.onPollabilityChanged = onPollabilityChanged
        self.window = window
        // Fresh installs start with the sidebar hidden -- a persisted user
        // choice (the key is present, either true or false) always wins.
        isSidebarVisible = defaults.object(forKey: "leo.sidebarVisible") as? Bool ?? false
        preferredWidth = (defaults.object(forKey: "leo.sidebarWidth") as? NSNumber).map { CGFloat($0.doubleValue) } ?? 260
        observeWindow()
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
        defaults.set(Double(width), forKey: "leo.sidebarWidth")
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
        let editor = editor
        Task { await editor.release() }
    }

    private func apply(_ event: LeoWindowVisibilityState.Event) {
        visibility.reduce(event)
        windowIsOccluded = visibility.isOccluded
        windowIsMiniaturized = visibility.isMiniaturized
    }

    private func changed() { onPollabilityChanged() }
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

    var sessions: [LeoWindowSession] { entries.values.compactMap(\.session) }

    private func report() {
        let before = entries.keys
        entries = entries.filter { $0.value.session != nil }
        for id in before where entries[id] == nil { onUnregistered(id) }
        pollabilityChanged(hasPollableSidebar)
    }
}
