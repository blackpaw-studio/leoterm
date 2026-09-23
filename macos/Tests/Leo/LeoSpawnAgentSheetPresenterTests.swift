import AppKit
import Foundation
import Testing

@testable import Ghostty

/// Review finding: `TerminalController` sets `window.contentView` directly
/// and never populates `window.contentViewController` -- so gating the
/// sheet presentation on that property (as the pre-fix code, mirroring
/// `TerminalController+Leo.newLeoAgent(_:)`, did) silently no-ops for every
/// real terminal window. `LeoSpawnAgentSheetPresenter` must still present a
/// sheet in that exact configuration.
@MainActor struct LeoSpawnAgentSheetPresenterTests {
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
        let actions = LeoAgentActions(
            daemon: StubDaemonClient(), cli: LeoCLI(), model: sidebar, hostSelection: LeoHostSelectionTestSupport.makeSelection(), refresh: {}
        )
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
