import AppKit
import GhosttyKit
import Testing

@testable import Ghostty

/// B-285: Agents ▸ Rename…, Delete… and Manage Hosts… must open their sheets
/// on a real terminal window. `TerminalController` sets `window.contentView`
/// directly and never a `contentViewController`, so presenting through that
/// property was a silent no-op (the same root cause as B-284). Needs the
/// app's real `Ghostty.App` for the window. Everything else is isolated: the
/// sheets get their own model, actions over a recording fake daemon, and an
/// in-memory host store, so nothing touches the app runtime or its daemon.
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

    private func makeSheets(daemon: RecordingDaemon) -> LeoAgentMenuSheets {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [scratch], connectivity: .connected, generation: 1))
        let hostSelection = LeoHostSelection.isolatedForTesting()
        let actions = LeoAgentActions(
            daemon: daemon, cli: .recordingForTests(), model: model, hostSelection: hostSelection,
            processRunner: LeoRecordingTemplateRunner(), refresh: {}
        )
        return LeoAgentMenuSheets(model: model, actions: actions, hostSelection: hostSelection)
    }

    private func expectSheet(on controller: TerminalController, after present: (NSWindow) -> Void) throws {
        let window = try #require(controller.window)
        present(window)
        let sheet = window.attachedSheet
        #expect(sheet != nil)
        if let sheet { window.endSheet(sheet) }
    }

    @Test func renamePresentsItsSheetOnATerminalWindow() throws {
        let controller = try makeController()
        defer { controller.closeTabImmediately(registerRedo: false) }
        let sheets = makeSheets(daemon: RecordingDaemon())

        try expectSheet(on: controller) { sheets.presentRename(scratch, in: $0) }
    }

    @Test func deletePresentsItsSheetOnATerminalWindowAndAsksTheFakeDaemonForItsPlan() async throws {
        let controller = try makeController()
        defer { controller.closeTabImmediately(registerRedo: false) }
        let daemon = RecordingDaemon()
        let sheets = makeSheets(daemon: daemon)
        let window = try #require(controller.window)

        sheets.presentDelete(scratch, in: window)

        #expect(window.attachedSheet != nil)
        await awaitCondition { await daemon.calls == ["plan:autopilot-scratch"] }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        #expect(await daemon.calls == ["plan:autopilot-scratch"], "presenting asks for the plan and does nothing else")
    }

    @Test func manageHostsPresentsItsSheetOnATerminalWindow() throws {
        let controller = try makeController()
        defer { controller.closeTabImmediately(registerRedo: false) }
        let sheets = makeSheets(daemon: RecordingDaemon())

        try expectSheet(on: controller) { sheets.presentManageHosts(in: $0) }
    }
}

/// Records every call it gets; the delete plan is canned. Anything the
/// sheets try beyond that fails the calls assertion.
private actor RecordingDaemon: LeoDaemonClient {
    private(set) var calls: [String] = []

    func listAgents() async throws -> [LeoAgent] { calls.append("list"); return [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { calls.append("spawn"); throw LeoDaemonError.transport("fake") }
    func start(_ name: String) async throws { calls.append("start:\(name)") }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { calls.append("stop:\(name)") }
    func restart(_ name: String) async throws -> LeoAgent { calls.append("restart:\(name)"); throw LeoDaemonError.transport("fake") }
    func reset(_ name: String) async throws { calls.append("reset:\(name)") }
    func setTemplate(_ name: String, template: String) async throws { calls.append("template:\(name)") }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { calls.append("rename:\(name)"); throw LeoDaemonError.transport("fake") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { calls.append("delete:\(name)") }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan {
        calls.append("plan:\(name)")
        return LeoDeletePlan(name: name, hasWorktree: false, branch: nil, worktreePath: nil)
    }
    func logs(_ name: String, lines: Int?) async throws -> String { calls.append("logs:\(name)"); return "" }
}
