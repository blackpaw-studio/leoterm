import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Review finding: `TerminalController` sets `window.contentView` directly
/// and never populates `window.contentViewController` -- so gating the
/// sheet presentation on that property (as the pre-fix code, mirroring
/// `TerminalController+Leo.newLeoAgent(_:)`, did) silently no-ops for every
/// real terminal window. `LeoSpawnAgentSheetPresenter` must still present a
/// sheet in that exact configuration.
@MainActor struct LeoSpawnAgentSheetPresenterTests {
    private func makeActions() -> (LeoSidebarModel, LeoAgentActions) {
        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: StubDaemonClient()), cli: .recordingForTests(), model: sidebar, processRunner: LeoRecordingTemplateRunner(), refresh: {})
        return (sidebar, actions)
    }

    @Test func presentsTheSpawnSheetThroughThePresenter() {
        let recorder = RecordingSheetPresenter()
        let (sidebar, actions) = makeActions()
        var completions = 0

        LeoSpawnAgentSheetPresenter(presenter: recorder.presenter)
            .present(on: RecordingSheetPresenter.plainWindow(), sidebar: sidebar, actions: actions) { _ in completions += 1 }

        #expect(recorder.presentedControllers.count == 1)
        #expect(recorder.presentedControllers.first is LeoSpawnSheetHostingController)
        #expect(completions == 0, "an open sheet has not resolved yet")
    }

    @Test func resolvesWithNilWhenThePresenterCannotPresent() {
        let (sidebar, actions) = makeActions()
        var results: [LeoAgentIdentity?] = []
        let refusing = LeoSheetPresenter(
            presentController: { _, _ in false }, presentWindow: { _, _, _ in }, dismissWindow: { _, _ in }, hasSheet: { _ in false })

        LeoSpawnAgentSheetPresenter(presenter: refusing)
            .present(on: RecordingSheetPresenter.plainWindow(), sidebar: sidebar, actions: actions) { results.append($0) }

        #expect(results.count == 1 && results[0] == nil)
    }

    @Test func presentsASheetOnAWindowWithNoContentViewController() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView() // mirrors TerminalController: no content view controller
        window.makeKeyAndOrderFront(nil)
        #expect(window.contentViewController == nil)

        let sidebar = LeoSidebarModel()
        let actions = LeoAgentActions(clients: FakeMachineClients(daemon: StubDaemonClient()), cli: .recordingForTests(), model: sidebar, processRunner: LeoRecordingTemplateRunner(), refresh: {})
        let presenter = LeoSpawnAgentSheetPresenter()

        presenter.present(on: window, sidebar: sidebar, actions: actions) { _ in }

        #expect(window.attachedSheet != nil)
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
