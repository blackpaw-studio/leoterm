import AppKit
import Combine
import OSLog
import SwiftUI

/// What `LeoPickerPresentation` needs to hand a `.newAgent` choice off to
/// the existing `SpawnAgentSheet`. Abstracted so tests can inject a fake
/// instead of a real `NSHostingController`/`presentAsSheet` round trip.
@MainActor protocol LeoSpawnSheetPresenting: AnyObject {
    func present(
        on window: NSWindow,
        sidebar: LeoSidebarModel,
        actions: LeoAgentActions,
        completion: @escaping (LeoAgentIdentity?) -> Void
    )
}

/// `NSHostingController` subclass that reports its own dismissal -- the
/// signal `LeoSpawnAgentSheetPresenter` needs to guarantee its completion
/// fires exactly once, regardless of *how* the sheet went away (attach,
/// Escape, or any other dismissal AppKit doesn't route through
/// `SpawnAgentSheet` itself).
@MainActor final class LeoSpawnSheetHostingController: NSHostingController<SpawnAgentSheet> {
    var onDisappear: (() -> Void)?

    override func viewDidDisappear() {
        super.viewDidDisappear()
        onDisappear?()
    }
}

/// Presents the real `SpawnAgentSheet` as a sheet on `window`, exactly as
/// `TerminalController.newLeoAgent(_:)` does today, but resolves to the
/// spawned agent's identity via `completion` instead of hardcoding an
/// attach disposition -- the caller (the router, via
/// `LeoPickerPresentation`) already knows where the result should land.
///
/// Terminal windows set `window.contentView` directly and never populate
/// `window.contentViewController` (see `TerminalController`'s
/// `window.contentView = container`), so gating on that property -- as
/// `TerminalController+Leo.newLeoAgent(_:)` does -- silently no-ops for
/// every real terminal window. Instead this builds a throwaway anchor
/// `NSViewController` whose `.view` IS the window's actual content view, so
/// `presentAsSheet` finds the right `.view.window` to attach to -- the same
/// machinery `presentAsSheet` always uses, just without requiring the
/// window to have been built around a content view controller in the first
/// place.
@MainActor final class LeoSpawnAgentSheetPresenter: LeoSpawnSheetPresenting {
    func present(
        on window: NSWindow,
        sidebar: LeoSidebarModel,
        actions: LeoAgentActions,
        completion: @escaping (LeoAgentIdentity?) -> Void
    ) {
        guard let contentView = window.contentView else {
            completion(nil)
            return
        }
        let anchor = NSViewController()
        anchor.view = contentView
        var resolved = false
        let resolve: (LeoAgentIdentity?) -> Void = { identity in
            guard !resolved else { return }
            resolved = true
            completion(identity)
        }
        let sheetView = SpawnAgentSheet(model: sidebar, actions: actions) { row, _ in
            resolve(row.identity)
        }
        let hosting = LeoSpawnSheetHostingController(rootView: sheetView)
        hosting.onDisappear = { resolve(nil) }
        anchor.presentAsSheet(hosting)
    }
}

/// Owns one window's agent palette: builds/updates the floating panel from
/// the sidebar snapshot + selected host + `LeoHostSelection.state`, maps
/// confirmed choices onto `LeoNewSurfaceRouter.chooseDetached(_:for:)`, and
/// handles the `.newAgent` spawn handoff. One instance per window, created
/// by `LeoRuntime.makeWindowSession(for:)` and torn down when the window
/// closes.
@MainActor final class LeoPickerPresentation {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private weak var window: NSWindow?
    private let router: LeoNewSurfaceRouter
    private let sidebar: LeoSidebarModel
    private let hostSelection: LeoHostSelection
    private let actions: LeoAgentActions
    private let panel: LeoAgentPalettePanelControlling
    private let spawnSheet: LeoSpawnSheetPresenting
    private let paletteModel: LeoAgentPaletteModel
    /// Tells this window's `LeoWindowSession` whether the palette is on
    /// screen -- a hidden sidebar alone would otherwise leave the window
    /// unpollable while the user is actively choosing an agent, showing a
    /// stale/empty list. See `LeoWindowSession.isPollable`.
    private let setPickerPresented: (Bool) -> Void

    private var activeRequest: LeoSurfaceRequest?
    /// True while the spawn sheet is up (palette hidden for it) -- guards
    /// `resignKey` from cancelling the request out from under the handoff.
    private var isSpawnHandoffInProgress = false
    /// True once a choice has been committed to the router and is expected
    /// to succeed (an attach in flight) -- also guards `resignKey`.
    private var isAttachInProgress = false
    /// Guards the deferred dismiss in `requestEnded(_:)` -- see its doc.
    private var pendingDismissToken = UUID()
    private var cancellables: Set<AnyCancellable> = []

    init(
        window: NSWindow,
        router: LeoNewSurfaceRouter,
        sidebar: LeoSidebarModel,
        hostSelection: LeoHostSelection,
        actions: LeoAgentActions,
        panel: LeoAgentPalettePanelControlling? = nil,
        spawnSheet: LeoSpawnSheetPresenting? = nil,
        setPickerPresented: @escaping (Bool) -> Void = { _ in }
    ) {
        self.window = window
        self.router = router
        self.sidebar = sidebar
        self.hostSelection = hostSelection
        self.actions = actions
        self.panel = panel ?? LeoAgentPalettePanel()
        self.spawnSheet = spawnSheet ?? LeoSpawnAgentSheetPresenter()
        self.setPickerPresented = setPickerPresented
        paletteModel = LeoAgentPaletteModel(retry: { [weak hostSelection] in hostSelection?.retry() })
        observeLiveState()
    }

    /// Shows (or, if already open for this window, reuses) the palette for
    /// `request`. The router's `begin(_:)` has already run by the time this
    /// is called (see `LeoRuntime.routeNewSurface`), so a second gesture for
    /// the same origin just needs to refocus and pick up the new request --
    /// not tear down and rebuild the panel.
    func present(request: LeoSurfaceRequest) {
        // There is one visible palette per window. A new leaf target replaces
        // an uncommitted visible gesture, but never cancels work already
        // committed for the old target.
        if let previous = activeRequest, previous.routingTarget != request.routingTarget, !isAttachInProgress {
            router.chooseDetached(.cancel, for: previous)
        }
        activeRequest = request
        isAttachInProgress = false
        paletteModel.clearFailure()
        paletteModel.reusesOpenTabs = request.disposition.reusesOpenTab
        refreshModel()
        Self.logger.log("present requestID=\(request.id.uuidString, privacy: .public) rows=\(self.paletteModel.rows.count) hostState=\(String(describing: self.hostSelection.state), privacy: .public)")
        guard window != nil else {
            router.chooseDetached(.cancel, for: request)
            return
        }
        guard !panel.isPresented else {
            panel.focusSearchField()
            return
        }
        showPanel()
    }

    /// Shared by `present(request:)` and `reportFailure(_:for:)` -- both
    /// need to (re-)show the panel wired to the same three callbacks.
    /// Requires `window` to already be non-nil; callers check that.
    private func showPanel() {
        guard let window else { return }
        setPickerPresented(true)
        panel.present(
            parent: window,
            model: paletteModel,
            onCommit: { [weak self] choice in self?.commit(choice) },
            onRetry: { [weak self] in self?.hostSelection.retry() },
            onResignKey: { [weak self] in self?.handleResignKey() }
        )
    }

    /// Wraps `panel.dismiss()` everywhere it's called so the picker-presented
    /// flag always tracks the panel's actual on-screen state.
    private func dismissPanel() {
        panel.dismiss()
        setPickerPresented(false)
    }

    /// Invoked by `LeoRuntime`'s per-window dispatch once the router commits
    /// to `.newAgent` for `request` -- hides the palette (without cancelling
    /// the request) and shows the spawn sheet.
    func presentSpawnSheet(for request: LeoSurfaceRequest, completion: @escaping (LeoAgentIdentity?) -> Void) {
        guard activeRequest == request, let window else {
            completion(nil)
            return
        }
        isSpawnHandoffInProgress = true
        dismissPanel()
        spawnSheet.present(on: window, sidebar: sidebar, actions: actions) { [weak self] identity in
            guard let self else {
                completion(identity)
                return
            }
            isSpawnHandoffInProgress = false
            // `request` (captured, not re-read) is this callback's identity
            // key: if a newer gesture has since superseded it, this sheet's
            // outcome must not touch `isAttachInProgress`/re-present state
            // that now belongs to a different request.
            guard activeRequest == request else {
                completion(identity)
                return
            }
            if identity != nil {
                isAttachInProgress = true
            } else {
                // Dismissed without spawning -- the request is still active
                // (the router never resolved it), so give the user another
                // chance to choose instead of leaving them with nothing.
                present(request: request)
            }
            completion(identity)
        }
    }

    /// Called via `LeoRuntime`'s dispatch for the router's `onFailure` hook
    /// -- keeps the palette open and surfaces the message inline instead of
    /// closing it.
    func reportFailure(_ error: LeoAttachError, for request: LeoSurfaceRequest) {
        guard activeRequest == request else { return }
        isAttachInProgress = false
        paletteModel.reportFailure(error.message)
        // A `.newAgent` handoff dismisses the panel for the sheet, then
        // (once spawn resolves) for the attach itself -- if THAT fails, the
        // panel is currently hidden with nowhere to show this message
        // unless it's re-shown here.
        if panel.isPresented {
            panel.focusSearchField()
        } else {
            showPanel()
        }
    }

    /// Called via `LeoRuntime`'s dispatch for the router's `onRequestEnded`
    /// hook -- fires on cancel, success, AND uncommitted supersede (a second
    /// same-origin gesture arriving before the first was ever chosen). Only
    /// success needs this to actually close the panel: cancel already
    /// dismissed it synchronously in `commit(_:)`, and a genuine window
    /// close goes through `invalidate()`. The tricky case is supersede --
    /// `LeoNewSurfaceRouter.begin(_:)` fires this for the *displaced*
    /// request before it stores the new one, so at this exact call there is
    /// no way to tell "the panel is about to be re-presented for a newer
    /// request" from "this is a real terminal outcome". Dismissing here
    /// unconditionally would flash the panel closed-then-reopened for every
    /// rapid double-gesture (e.g. two Cmd+T).
    ///
    /// Instead this defers the actual dismiss by one main-thread runloop
    /// turn: `LeoRuntime.routeNewSurface` always calls `present(_:)`
    /// synchronously right after `begin(_:)` triggers this, so by the time
    /// the deferred check runs, a genuine supersede has already set
    /// `activeRequest` to the new request (via `present(request:)`) and the
    /// dismiss is skipped; a genuine terminal outcome leaves it `nil` and
    /// the dismiss goes through.
    func requestEnded(_ request: LeoSurfaceRequest) {
        guard activeRequest == request else { return }
        activeRequest = nil
        isAttachInProgress = false
        let token = UUID()
        pendingDismissToken = token
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingDismissToken == token, self.activeRequest == nil else { return }
            self.dismissPanel()
        }
    }

    /// The parent window closed -- tear everything down unconditionally.
    func invalidate() {
        dismissPanel()
        activeRequest = nil
        isSpawnHandoffInProgress = false
        isAttachInProgress = false
    }

    private func commit(_ choice: LeoPickerChoice) {
        guard let request = activeRequest else { return }
        switch choice {
        case .cancel:
            dismissPanel()
            activeRequest = nil
            router.chooseDetached(.cancel, for: request)
        case .newAgent:
            router.chooseDetached(.newAgent, for: request)
        case .agent, .plainShell:
            isAttachInProgress = true
            router.chooseDetached(choice, for: request)
        }
    }

    private func handleResignKey() {
        guard !isSpawnHandoffInProgress, !isAttachInProgress, let request = activeRequest else { return }
        dismissPanel()
        activeRequest = nil
        router.chooseDetached(.cancel, for: request)
    }

    private func refreshModel() {
        paletteModel.update(snapshot: sidebar.snapshot, selectedHost: hostSelection.selected, hostState: hostSelection.state)
    }

    /// Feeds `paletteModel` from the *emitted* values of each publisher,
    /// never by re-reading the source properties afterward: `@Published`
    /// emits from `willSet`, so a subscriber that reads `sidebar.snapshot`/
    /// `hostSelection.state` etc. back out of its own sink closure sees the
    /// value from BEFORE this emission -- one update behind (e.g. a
    /// `.failed` transition could still read back as `.connecting`, hiding
    /// the Retry affordance).
    private func observeLiveState() {
        Publishers.CombineLatest3(sidebar.$snapshot, hostSelection.$selected, hostSelection.$state)
            .sink { [weak self] snapshot, selectedHost, hostState in
                self?.paletteModel.update(snapshot: snapshot, selectedHost: selectedHost, hostState: hostState)
            }
            .store(in: &cancellables)
    }
}

/// Routes `LeoNewSurfaceRouter`'s single shared callbacks (`presentSpawn`,
/// `onFailure`, `onRequestEnded`) to the right window's `LeoPickerPresentation`
/// by the request's `origin`. Owned by `LeoRuntime`; entries are added in
/// `makeWindowSession(for:)` and removed when the window's session
/// unregisters. Implements `LeoPickerPresenting` itself so `LeoRuntime` can
/// hand it straight to `routeNewSurface`.
@MainActor final class LeoWindowPickerRouter: LeoPickerPresenting {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private var presentations: [LeoWindowID: LeoPickerPresentation] = [:]

    /// Fired (in addition to the `error` log) whenever `present(request:)`
    /// finds no registered presentation for the request's origin -- tests
    /// observe this directly rather than capturing unified-logging output.
    /// Production leaves this as the default no-op.
    var onMissingPresentation: (LeoSurfaceRequest) -> Void = { _ in }

    func register(_ presentation: LeoPickerPresentation, for origin: LeoWindowID) {
        presentations[origin] = presentation
        Self.logger.log("LeoWindowPickerRouter.register origin=\(origin.rawValue.uuidString, privacy: .public)")
    }

    func unregister(origin: LeoWindowID) {
        presentations.removeValue(forKey: origin)?.invalidate()
    }

    func present(request: LeoSurfaceRequest) {
        guard let presentation = presentations[request.origin] else {
            Self.logger.error(
                "LeoWindowPickerRouter.present: no presentation registered for origin=\(request.origin.rawValue.uuidString, privacy: .public) requestID=\(request.id.uuidString, privacy: .public) knownOrigins=\(self.presentations.keys.map(\.rawValue.uuidString), privacy: .public)"
            )
            onMissingPresentation(request)
            return
        }
        presentation.present(request: request)
    }

    func presentSpawn(for request: LeoSurfaceRequest, completion: @escaping (LeoAgentIdentity?) -> Void) {
        guard let presentation = presentations[request.origin] else {
            completion(nil)
            return
        }
        presentation.presentSpawnSheet(for: request, completion: completion)
    }

    func reportFailure(_ error: LeoAttachError, for request: LeoSurfaceRequest) {
        presentations[request.origin]?.reportFailure(error, for: request)
    }

    func requestEnded(_ request: LeoSurfaceRequest) {
        presentations[request.origin]?.requestEnded(request)
    }
}
