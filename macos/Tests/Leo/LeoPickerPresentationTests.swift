import AppKit
import Foundation
import Testing

@testable import Ghostty

@MainActor struct LeoPickerPresentationTests {
    private let origin = LeoWindowID()
    private let identity = LeoAgentIdentity(host: .local, name: "spawned")

    private func makeSidebar(rows: [LeoAgentRow] = []) -> LeoSidebarModel {
        let model = LeoSidebarModel()
        model.receive(LeoSidebarSnapshot(rows: rows, connectivity: .connected, generation: 1))
        return model
    }

    /// Both `store:` and `defaults:` must be isolated: `defaults:` is where
    /// `LeoHostSelection.select(_:)` persists `"leo.selectedHost"` (and
    /// reads it back at init) -- using the real `.standard` domain here
    /// would leak this suite's `select(.remote(...))` calls into every other
    /// test that default-constructs a `LeoHostSelection` against `.standard`.
    private func makeHostSelection() -> LeoHostSelection {
        let defaults = UserDefaults(suiteName: "LeoPickerPresentationTests.\(UUID().uuidString)")!
        return LeoHostSelection(store: LeoHostStore(defaults: defaults), defaults: defaults)
    }

    private func makeActions(sidebar: LeoSidebarModel, hostSelection: LeoHostSelection) -> LeoAgentActions {
        LeoAgentActions(daemon: StubDaemonClient(), cli: LeoCLI(), model: sidebar, hostSelection: hostSelection, refresh: {})
    }

    private struct Environment {
        let window: NSWindow
        let router: LeoNewSurfaceRouter
        let routerSpy: RouterSpy
        let pickerRouter: LeoWindowPickerRouter
        let sidebar: LeoSidebarModel
        let hostSelection: LeoHostSelection
        let panel: FakePalettePanel
        let sheet: FakeSpawnSheet
        let presentation: LeoPickerPresentation
        let pickerPresentedEvents: PickerPresentedRecorder
    }

    /// Records every `setPickerPresented(_:)` call `LeoPickerPresentation`
    /// makes, standing in for `LeoWindowSession.setPickerPresented(_:)`.
    @MainActor final class PickerPresentedRecorder {
        private(set) var events: [Bool] = []
        func record(_ presented: Bool) { events.append(presented) }
    }

    /// Wires the router's `presentSpawn`/`onFailure`/`onRequestEnded`
    /// through a real `LeoWindowPickerRouter` (exactly as `LeoRuntime`
    /// does), not straight into the spy -- so supersede, spawn-handoff, and
    /// failure-recovery all exercise the actual dispatch-by-origin path,
    /// not just `LeoPickerPresentation`'s methods called directly.
    private func makeEnvironment(rows: [LeoAgentRow] = []) -> Environment {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let sidebar = makeSidebar(rows: rows)
        let hostSelection = makeHostSelection()
        let actions = makeActions(sidebar: sidebar, hostSelection: hostSelection)
        let pickerRouter = LeoWindowPickerRouter()
        let spy = RouterSpy()
        let router = spy.makeRouter(pickerRouter: pickerRouter)
        let panel = FakePalettePanel()
        let sheet = FakeSpawnSheet()
        let pickerPresentedEvents = PickerPresentedRecorder()
        let presentation = LeoPickerPresentation(
            window: window, router: router, sidebar: sidebar, hostSelection: hostSelection,
            actions: actions, panel: panel, spawnSheet: sheet,
            setPickerPresented: { [pickerPresentedEvents] presented in pickerPresentedEvents.record(presented) }
        )
        pickerRouter.register(presentation, for: origin)
        return Environment(
            window: window, router: router, routerSpy: spy, pickerRouter: pickerRouter, sidebar: sidebar,
            hostSelection: hostSelection, panel: panel, sheet: sheet, presentation: presentation,
            pickerPresentedEvents: pickerPresentedEvents
        )
    }

    @Test func presentFeedsModelWithCurrentSnapshot() {
        let row = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .idle, actionDetail: nil)
        let env = makeEnvironment(rows: [row])
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)

        env.presentation.present(request: request)

        #expect(env.panel.presentCallCount == 1)
        #expect(env.panel.lastModel?.rows.contains { if case .agent(let agentRow) = $0 { agentRow.name == "alpha" } else { false } } == true)
    }

    @Test func confirmedAgentChoiceCommitsToRouter() async {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        env.panel.onCommit?(.agent(identity))
        await waitFor { env.routerSpy.attachCalls.count == 1 }

        #expect(env.routerSpy.attachCalls.first?.0 == identity)
    }

    @Test func cancelDismissesPanelAndRouterReceivesCancel() async {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        env.panel.onCommit?(.cancel)
        await waitFor { env.routerSpy.cancelledRequests.contains(request) }

        #expect(env.panel.dismissCallCount == 1)
    }

    /// Presenting the palette must mark the window pollable even with a
    /// hidden sidebar (`LeoWindowSession.isPollable`), and cancelling must
    /// release that -- otherwise a window with the sidebar hidden shows a
    /// stale/empty agent list the moment the palette opens.
    @Test func presentingAndCancellingTogglePickerPresentedForPolling() async {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        #expect(env.pickerPresentedEvents.events == [true])

        env.panel.onCommit?(.cancel)
        await waitFor { env.routerSpy.cancelledRequests.contains(request) }

        #expect(env.pickerPresentedEvents.events == [true, false])
    }

    @Test func resignKeyCancelsWhenNoHandoffOrAttachInProgress() async {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        env.panel.onResignKey?()
        await waitFor { env.routerSpy.cancelledRequests.contains(request) }

        #expect(env.panel.dismissCallCount == 1)
    }

    @Test func resignKeyDoesNothingDuringSpawnHandoff() {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        env.presentation.presentSpawnSheet(for: request) { _ in }
        // Spawn sheet is up (fake never resolved) -- the palette panel was
        // dismissed for the handoff. A resign-key on it must be ignored.
        env.panel.onResignKey?()

        #expect(env.routerSpy.cancelledRequests.isEmpty)
    }

    @Test func resignKeyDoesNothingDuringInFlightAttach() async {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.routerSpy.attachGate = ChooseGate()
        env.router.begin(request)
        env.presentation.present(request: request)

        env.panel.onCommit?(.agent(identity))
        await env.routerSpy.attachGate!.waitUntilEntered()
        env.panel.onResignKey?()

        #expect(env.routerSpy.cancelledRequests.isEmpty)
        await env.routerSpy.attachGate!.releaseAll()
    }

    @Test func spawnHandoffCompletesOnceWithIdentity() {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        var completions: [LeoAgentIdentity?] = []
        env.presentation.presentSpawnSheet(for: request) { completions.append($0) }
        #expect(env.sheet.presentCallCount == 1)
        #expect(env.panel.dismissCallCount == 1)

        env.sheet.resolve(identity)
        #expect(completions == [identity])
    }

    @Test func spawnHandoffCompletesOnceWithNilOnDismiss() {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        var completions: [LeoAgentIdentity?] = []
        env.presentation.presentSpawnSheet(for: request) { completions.append($0) }
        env.sheet.resolve(nil)

        #expect(completions == [nil])
        // Dismissed without spawning -- the request is still active, so the
        // palette re-presents itself.
        #expect(env.panel.presentCallCount == 2)
    }

    /// Review finding: a superseded spawn sheet's late identity callback
    /// must not mutate state that now belongs to a *different* (newer)
    /// request -- keyed by `activeRequest == request` at resolve time, not
    /// by whatever was active when the sheet was first presented.
    @Test func supersededSpawnSheetCallbackIgnoresStateForTheOldRequest() async {
        let env = makeEnvironment()
        let first = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(first)
        env.presentation.present(request: first)

        var completions: [LeoAgentIdentity?] = []
        env.presentation.presentSpawnSheet(for: first) { completions.append($0) }
        #expect(env.panel.dismissCallCount == 1) // hidden for the handoff

        // A second, newer request takes over this window's palette while
        // the first's spawn sheet is still outstanding.
        let second = LeoSurfaceRequest(origin: origin, disposition: .window)
        env.router.begin(second)
        env.presentation.present(request: second)
        #expect(env.panel.presentCallCount == 2) // re-shown fresh for `second`

        // The stale sheet finally resolves with an identity for `first`.
        env.sheet.resolve(identity)

        #expect(completions == [identity], "the completion must still fire exactly once")
        // Must not have re-presented (the `nil` branch) or otherwise
        // touched the panel on `second`'s behalf.
        #expect(env.panel.presentCallCount == 2)
        // `second` must still be cancellable normally -- if the stale
        // callback had wrongly marked an attach in progress for `second`,
        // this resign-key would be swallowed.
        env.panel.onResignKey?()
        await waitFor { env.routerSpy.cancelledRequests.contains(second) }
        #expect(env.routerSpy.cancelledRequests.contains(second))
    }

    @Test func failureKeepsRequestActiveAndShowsMessage() {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        env.presentation.reportFailure(.init(identity: identity, kind: .openFailed("boom")), for: request)

        #expect(env.panel.dismissCallCount == 0)
        #expect(env.panel.lastModel?.attachError == "boom")
    }

    /// Review finding: a `.newAgent` handoff that spawns successfully but
    /// then fails to attach left the palette hidden (dismissed for the
    /// handoff) with the failure message set on a model nobody could see.
    @Test func spawnThenAttachFailureRePresentsThePalette() async {
        let env = makeEnvironment()
        env.routerSpy.attachResult = .failure(.init(identity: identity, kind: .openFailed("boom")))
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)
        #expect(env.panel.presentCallCount == 1)

        env.panel.onCommit?(.newAgent)
        await waitFor { env.sheet.presentCallCount == 1 }
        #expect(env.panel.dismissCallCount == 1) // hidden for the handoff

        env.sheet.resolve(identity)
        await waitFor { env.panel.lastModel?.attachError == "boom" }

        #expect(env.routerSpy.attachCalls.count == 1)
        #expect(env.panel.presentCallCount == 2, "the palette must re-present to show the failure")
    }

    @Test func parentCloseInvalidatesAndClosesPanel() {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        env.presentation.invalidate()

        #expect(env.panel.dismissCallCount == 1)
    }

    /// Review finding: `requestEnded` for a superseded (never-chosen)
    /// request used to dismiss the panel synchronously, and the very next
    /// call (`present` for the new request) then rebuilt it -- a visible
    /// close-then-reopen flicker for something as routine as a second
    /// Cmd+T. This drives the exact production sequence
    /// (`router.begin` -> `onRequestEnded` dispatched via the real
    /// `LeoWindowPickerRouter` -> `present`) and asserts the panel is
    /// presented exactly once and never dismissed.
    @Test func supersedingBeginKeepsThePanelPresentedExactlyOnceWithTheNewRequest() async {
        let env = makeEnvironment()
        let first = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(first)
        env.presentation.present(request: first)
        #expect(env.panel.presentCallCount == 1)

        let second = LeoSurfaceRequest(origin: origin, disposition: .split(.right))
        env.router.begin(second) // fires onRequestEnded(first) via LeoWindowPickerRouter synchronously
        env.presentation.present(request: second)

        #expect(env.panel.presentCallCount == 1, "a repeated gesture must not tear down and rebuild the panel")
        #expect(env.panel.focusCallCount == 1)

        // Let the deferred dismiss (see `LeoPickerPresentation.requestEnded`)
        // get a chance to run -- it must find `second` active and skip it.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(env.panel.dismissCallCount == 0, "the deferred dismiss must have detected the newer active request and skipped")

        env.panel.onCommit?(.plainShell)
        await waitFor { env.routerSpy.openPlainShellCalls == [second] }
        #expect(env.routerSpy.openPlainShellCalls == [second], "the reused panel must resolve the updated (second) request")
    }

    /// Review finding: the live Combine sinks used to re-read
    /// `hostSelection.state`/`selected` from inside their own `.sink`
    /// closures instead of using the emitted values -- since `@Published`
    /// emits from `willSet`, that re-read one update behind (a `.failed`
    /// transition could still read back as `.connecting`, hiding Retry).
    /// `select(_:)` on an unconfigured remote host publishes `.connecting`
    /// then `.failed` synchronously (no ssh spawn needed), so this needs no
    /// async wait to prove the update lands immediately.
    @Test func liveHostStateUpdateUsesTheEmittedValueNotAStaleRead() {
        let env = makeEnvironment()
        let request = LeoSurfaceRequest(origin: origin, disposition: .tab)
        env.router.begin(request)
        env.presentation.present(request: request)

        env.hostSelection.select(.remote("nonexistent-host"))

        guard case .status(let text, _, let canRetry) = env.panel.lastModel?.rows.first else {
            Issue.record("expected a status row reflecting the failed connection")
            return
        }
        #expect(text.contains("Unknown host"))
        #expect(canRetry)
    }
}

private func waitFor(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

// MARK: - Fakes

@MainActor private final class FakePalettePanel: LeoAgentPalettePanelControlling {
    private(set) var isPresented = false
    private(set) var presentCallCount = 0
    private(set) var focusCallCount = 0
    private(set) var dismissCallCount = 0
    private(set) var lastModel: LeoAgentPaletteModel?
    var onCommit: ((LeoPickerChoice) -> Void)?
    var onResignKey: (() -> Void)?

    func present(
        parent: NSWindow,
        model: LeoAgentPaletteModel,
        onCommit: @escaping (LeoPickerChoice) -> Void,
        onRetry: @escaping () -> Void,
        onResignKey: @escaping () -> Void
    ) {
        presentCallCount += 1
        isPresented = true
        lastModel = model
        self.onCommit = onCommit
        self.onResignKey = onResignKey
    }

    func focusSearchField() { focusCallCount += 1 }

    func dismiss() {
        dismissCallCount += 1
        isPresented = false
    }
}

@MainActor private final class FakeSpawnSheet: LeoSpawnSheetPresenting {
    private(set) var presentCallCount = 0
    private var pendingCompletion: ((LeoAgentIdentity?) -> Void)?

    func present(
        on window: NSWindow, sidebar: LeoSidebarModel, actions: LeoAgentActions,
        completion: @escaping (LeoAgentIdentity?) -> Void
    ) {
        presentCallCount += 1
        pendingCompletion = completion
    }

    func resolve(_ identity: LeoAgentIdentity?) {
        pendingCompletion?(identity)
        pendingCompletion = nil
    }
}

/// Mirrors `LeoNewSurfaceRouterTests`' `RouterSpy`, but wires
/// `presentSpawn`/`onFailure`/`onRequestEnded` through a real
/// `LeoWindowPickerRouter` (see `makeEnvironment`) instead of recording them
/// directly -- this suite needs the actual dispatch-by-origin behavior, not
/// just a record of "was this closure called". `LeoNewSurfaceRouter` makes
/// no dedicated callback for `.cancel` -- it just retires the request
/// (`onRequestEnded`) without ever calling `attach`/`openPlainShell`/
/// `presentSpawn`. `cancelledRequests` reconstructs "was this a cancel" from
/// that: a request that ended without ever reaching one of those three
/// closures was cancelled (success/spawn-attach always call one first).
@MainActor private final class RouterSpy {
    var attachCalls: [(LeoAgentIdentity, LeoSurfaceRequest)] = []
    var openPlainShellCalls: [LeoSurfaceRequest] = []
    var attachGate: ChooseGate?
    var attachResult: Result<Void, LeoAttachError> = .success(())
    private var endedRequests: [LeoSurfaceRequest] = []
    private var workedRequests: [LeoSurfaceRequest] = []

    var cancelledRequests: [LeoSurfaceRequest] {
        endedRequests.filter { ended in !workedRequests.contains(where: { $0 == ended }) }
    }

    func makeRouter(pickerRouter: LeoWindowPickerRouter) -> LeoNewSurfaceRouter {
        LeoNewSurfaceRouter(
            attach: { [weak self] identity, request in
                self?.attachCalls.append((identity, request))
                self?.workedRequests.append(request)
                if let gate = self?.attachGate { await gate.enterAndWaitForRelease() }
                return self?.attachResult ?? .success(())
            },
            openPlainShell: { [weak self] request in
                self?.openPlainShellCalls.append(request)
                self?.workedRequests.append(request)
                return .success(())
            },
            presentSpawn: { [weak self, weak pickerRouter] request, complete in
                self?.workedRequests.append(request)
                guard let pickerRouter else {
                    complete(nil)
                    return
                }
                pickerRouter.presentSpawn(for: request, completion: complete)
            },
            onFailure: { [weak pickerRouter] request, error in
                pickerRouter?.reportFailure(error, for: request)
            },
            onRequestEnded: { [weak self, weak pickerRouter] request in
                self?.endedRequests.append(request)
                pickerRouter?.requestEnded(request)
            }
        )
    }
}

private actor ChooseGate {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWaitForRelease() async {
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { pending.append($0) }
    }

    func waitUntilEntered() async {
        guard pending.isEmpty else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func releaseAll() {
        let all = pending
        pending.removeAll()
        for continuation in all { continuation.resume() }
    }
}

private struct StubDaemonClient: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func start(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func reset(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func setTemplate(_ name: String, template: String) async throws { throw LeoDaemonError.transport("unused") }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.transport("unused") }
    func logs(_ name: String, lines: Int?) async throws -> String { throw LeoDaemonError.transport("unused") }
}
