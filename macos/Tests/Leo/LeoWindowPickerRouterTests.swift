import AppKit
import Foundation
import Testing

@testable import Ghostty

/// Regression coverage for a launch bug: `routeNewSurface` and
/// `LeoNewSurfaceRouter.begin` both logged, but `LeoWindowPickerRouter`
/// silently found no presentation for the origin and the palette never
/// appeared. The actual root cause turned out to be upstream
/// (`TerminalController.surfaceTreeDidChange` closing every Leo placeholder
/// window the instant its empty tree triggered `windowDidLoad`, torn down
/// before the router's `present` call ever ran) -- not a registration-order
/// bug in `LeoWindowPickerRouter` itself. These tests cover the router's own
/// contract directly: a present for an unregistered origin is observable
/// (not silently dropped), and a registered presentation is the one found.
@MainActor struct LeoWindowPickerRouterTests {
    private let origin = LeoWindowID()

    @Test func presentForUnregisteredOriginIsObservableAndDoesNotCrash() {
        let router = LeoWindowPickerRouter()
        var missed: [LeoSurfaceRequest] = []
        router.onMissingPresentation = { missed.append($0) }
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder)

        router.present(request: request)

        #expect(missed == [request])
    }

    /// Mirrors what `LeoRuntime.makeWindowSession(for:)` does once
    /// `controller.window` is available: build a `LeoPickerPresentation` and
    /// `register(_:for:)` it under the window's origin. A `present(request:)`
    /// for that same origin must find it, not drop it.
    @Test func registeredPresentationReceivesPresentForItsOrigin() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false
        )
        let sidebar = LeoSidebarModel()
        let suite = "LeoWindowPickerRouterTests.\(UUID().uuidString)"
        let hostDefaults = UserDefaults(suiteName: suite)!
        let hostSelection = LeoHostSelection.isolatedForTesting(defaults: hostDefaults)
        let actions = LeoAgentActions(daemon: StubDaemonClient(), cli: LeoCLI(), model: sidebar, hostSelection: hostSelection, refresh: {})
        let router = LeoNewSurfaceRouter(
            attach: { _, _ in .success(()) },
            openPlainShell: { _ in .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
        let panel = FakePalettePanel()
        let presentation = LeoPickerPresentation(
            window: window, router: router, sidebar: sidebar, hostSelection: hostSelection,
            actions: actions, panel: panel, spawnSheet: FakeSpawnSheet()
        )
        let pickerRouter = LeoWindowPickerRouter()
        var missed: [LeoSurfaceRequest] = []
        pickerRouter.onMissingPresentation = { missed.append($0) }
        pickerRouter.register(presentation, for: origin)

        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder)
        router.begin(request)
        pickerRouter.present(request: request)

        #expect(panel.presentCallCount == 1)
        #expect(missed.isEmpty)
    }

    /// A leaf-targeted placeholder request (`surfaceID` non-nil) is keyed
    /// the same as any other request -- by `origin` -- for dispatch
    /// purposes. `LeoWindowPickerRouter` forwards it unchanged through
    /// `present`, `presentSpawn`, `reportFailure`, and `requestEnded` to the
    /// one presentation registered for that window; the target only matters
    /// to `LeoPickerPresentation` (see `LeoPickerPresentationTests`), not to
    /// this dispatch layer.
    @Test func routesTargetedPlaceholderRequestToItsWindowPresentation() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false
        )
        let sidebar = LeoSidebarModel()
        let suite = "LeoWindowPickerRouterTests.\(UUID().uuidString)"
        let hostDefaults = UserDefaults(suiteName: suite)!
        let hostSelection = LeoHostSelection.isolatedForTesting(defaults: hostDefaults)
        let actions = LeoAgentActions(daemon: StubDaemonClient(), cli: LeoCLI(), model: sidebar, hostSelection: hostSelection, refresh: {})
        let router = LeoNewSurfaceRouter(
            attach: { _, _ in .success(()) },
            openPlainShell: { _ in .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
        let panel = FakePalettePanel()
        let presentation = LeoPickerPresentation(
            window: window, router: router, sidebar: sidebar, hostSelection: hostSelection,
            actions: actions, panel: panel, spawnSheet: FakeSpawnSheet()
        )
        let pickerRouter = LeoWindowPickerRouter()
        var missed: [LeoSurfaceRequest] = []
        pickerRouter.onMissingPresentation = { missed.append($0) }
        pickerRouter.register(presentation, for: origin)

        let surfaceID = UUID()
        let request = LeoSurfaceRequest(origin: origin, disposition: .placeholder(surfaceID: surfaceID))
        router.begin(request)
        pickerRouter.present(request: request)

        #expect(panel.presentCallCount == 1)
        #expect(missed.isEmpty)

        pickerRouter.reportFailure(.init(identity: LeoAgentIdentity(host: .local, name: "a"), kind: .openFailed("boom")), for: request)
        #expect(panel.lastModel?.attachError == "boom")

        pickerRouter.requestEnded(request)
    }
}

@MainActor private final class FakePalettePanel: LeoAgentPalettePanelControlling {
    private(set) var isPresented = false
    private(set) var presentCallCount = 0
    private(set) var lastModel: LeoAgentPaletteModel?

    func present(
        parent: NSWindow, model: LeoAgentPaletteModel, onCommit: @escaping (LeoPickerChoice) -> Void,
        onRetry: @escaping () -> Void, onResignKey: @escaping () -> Void
    ) {
        presentCallCount += 1
        isPresented = true
        lastModel = model
    }

    func focusSearchField() {}

    func dismiss() { isPresented = false }
}

@MainActor private final class FakeSpawnSheet: LeoSpawnSheetPresenting {
    func present(
        on window: NSWindow, sidebar: LeoSidebarModel, actions: LeoAgentActions,
        completion: @escaping (LeoAgentIdentity?) -> Void
    ) {
        completion(nil)
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
