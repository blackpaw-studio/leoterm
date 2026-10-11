import AppKit
import GhosttyKit
import Testing

@testable import Ghostty

/// B-285: Agents ▸ Rename…, Delete… and Manage Hosts… must open their sheets
/// on a real terminal window. `TerminalController` sets `window.contentView`
/// directly and never a `contentViewController`, so presenting through that
/// property was a silent no-op (the same root cause as B-284). Needs the
/// app's real `Ghostty.App`. The selected row is a made-up
/// `autopilot-scratch` fed to the shared model; each sheet is dismissed
/// without confirming, so nothing reaches the daemon.
@MainActor @Suite(.serialized) struct LeoAgentMenuSheetTests {
    private let scratch = LeoAgentRow(
        host: .local, name: "autopilot-scratch", template: nil, status: .running, activity: .idle, actionDetail: nil
    )

    private func makeController() throws -> TerminalController {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty, "needs the app's Ghostty.App")
        let app = try #require(ghostty.app)
        let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: Ghostty.SurfaceView(app, baseConfig: nil)))
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let registry = LeoWindowSessionRegistry()
        _ = registry.makeSession(window: window, controller: controller, defaults: LeoInMemoryDefaults())
        window.makeKeyAndOrderFront(nil)
        #expect(window.contentViewController == nil)
        return controller
    }

    /// Selects `scratch` in the app's model, connected, one generation past
    /// whatever the live feed last published (a later live snapshot simply
    /// replaces it and drops the selection).
    private func selectScratch(in model: LeoSidebarModel) {
        model.receive(LeoSidebarSnapshot(rows: [scratch], connectivity: .connected, generation: model.snapshot.generation + 1))
        model.selection = scratch.id
    }

    private func expectSheet(on controller: TerminalController, after action: (TerminalController) -> Void) throws {
        let window = try #require(controller.window)
        action(controller)
        let sheet = window.attachedSheet
        #expect(sheet != nil)
        if let sheet { window.endSheet(sheet) }
    }

    @Test func renamePresentsItsSheetOnATerminalWindow() throws {
        let controller = try makeController()
        defer { controller.closeTabImmediately(registerRedo: false) }
        let model = try #require(controller.leoRuntime).model
        selectScratch(in: model)
        defer { model.selection = nil }

        try expectSheet(on: controller) { $0.renameSelectedLeoAgent(nil) }
    }

    @Test func deletePresentsItsSheetOnATerminalWindow() throws {
        let controller = try makeController()
        defer { controller.closeTabImmediately(registerRedo: false) }
        let model = try #require(controller.leoRuntime).model
        selectScratch(in: model)
        defer { model.selection = nil }

        try expectSheet(on: controller) { $0.deleteSelectedLeoAgent(nil) }
    }

    @Test func manageHostsPresentsItsSheetOnATerminalWindow() throws {
        let controller = try makeController()
        defer { controller.closeTabImmediately(registerRedo: false) }

        try expectSheet(on: controller) { $0.manageLeoHosts(nil) }
    }
}
