import AppKit
import GhosttyKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-285: Agents ▸ Rename…, and Delete… must open their sheets
/// on a real terminal window. `TerminalController` sets `window.contentView`
/// directly and never a `contentViewController`, so presenting through that
/// property was a silent no-op (the same root cause as B-284). The sheets are
/// checked against a recording presenter; the real-window cases run on
/// a plain window too. Everything is isolated: the
/// sheets get their own model, actions over a recording fake daemon, and an
/// in-memory host store, so nothing touches the app runtime or its daemon.
@MainActor @Suite(.serialized) struct LeoAgentMenuSheetTests {
    private let scratch = LeoAgentRow(
        host: .local, name: "autopilot-scratch", template: nil, status: .running, activity: .idle, actionDetail: nil
    )

    private func makeSheets(daemon: RecordingDaemon, presenter: LeoSheetPresenter = .live) -> LeoAgentMenuSheets {
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [scratch], connectivity: .connected, generation: 1))
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemon: daemon), cli: .recordingForTests(), model: model, processRunner: LeoRecordingTemplateRunner(), refresh: {}
        )
        return LeoAgentMenuSheets(model: model, actions: actions, presenter: presenter)
    }

    @Test func renamePresentsItsSheet() {
        let recorder = RecordingSheetPresenter()
        let sheets = makeSheets(daemon: RecordingDaemon(), presenter: recorder.presenter)

        sheets.presentRename(scratch, in: RecordingSheetPresenter.plainWindow())

        #expect(recorder.presentedControllers.count == 1)
    }

    @Test func deletePresentsItsSheetAndDoesNothingElseUntilItAppears() async {
        let recorder = RecordingSheetPresenter()
        let daemon = RecordingDaemon()
        let sheets = makeSheets(daemon: daemon, presenter: recorder.presenter)

        sheets.presentDelete(scratch, in: RecordingSheetPresenter.plainWindow())

        #expect(recorder.presentedControllers.count == 1)
        #expect(await daemon.calls.isEmpty, "presenting alone calls nothing; the sheet asks for its plan when it appears")
    }

    @Test func nothingIsPresentedWithoutAWindow() {
        let recorder = RecordingSheetPresenter()
        let sheets = makeSheets(daemon: RecordingDaemon(), presenter: recorder.presenter)

        sheets.presentRename(scratch, in: nil)
        sheets.presentDelete(scratch, in: nil)

        #expect(recorder.presentedControllers.isEmpty)
    }

    /// B-285: the real sheet appears on a window with `contentView` set and
    /// no `contentViewController` (as `TerminalController` builds it), and the
    /// delete sheet then asks the daemon for its plan.
    @Test func deleteSheetAppearsOnARealWindowAndAsksForItsPlan() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView()
        window.isReleasedWhenClosed = false // close() must not over-release (autorelease-pool crash)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        #expect(window.contentViewController == nil)
        let daemon = RecordingDaemon()

        makeSheets(daemon: daemon).presentDelete(scratch, in: window)

        #expect(window.attachedSheet != nil)
        await awaitCondition { await daemon.calls == ["plan:autopilot-scratch"] }
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    /// B-328: SwiftUI's `dismiss` does nothing in a hosting controller that
    /// `presentLeoSheet` attached outside SwiftUI, so Cancel and confirm left
    /// Rename, Delete and New Agent open. The sheets close through
    /// `LeoSheetDismiss`, which ends the window's sheet.
    @Test func leoSheetDismissClosesASheetPresentedOnATerminalWindow() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView()
        window.isReleasedWhenClosed = false // close() must not over-release (autorelease-pool crash)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let probe = DismissProbe()

        window.presentLeoSheet(NSHostingController(rootView: DismissProbeView(probe: probe).leoSheetClose(in: window)))
        await awaitCondition { @MainActor in probe.dismiss != nil }
        #expect(window.attachedSheet != nil)

        probe.dismiss?()
        await awaitCondition { @MainActor in window.attachedSheet == nil }

        let leftOpen = window.attachedSheet
        if let leftOpen { window.endSheet(leftOpen) }
        #expect(leftOpen == nil, "dismiss leaves the sheet open")
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

@MainActor private final class DismissProbe {
    var dismiss: (() -> Void)?
}

private struct DismissProbeView: View {
    let probe: DismissProbe
    private let dismiss = LeoSheetDismiss()

    var body: some View {
        Text("probe").frame(width: 120, height: 60).onAppear { probe.dismiss = { dismiss() } }
    }
}
