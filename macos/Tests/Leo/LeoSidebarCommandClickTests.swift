import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-048: ⌘-click on a sidebar row, through the real list. The clicks are
/// posted to the app's event queue, so they reach the row the way the
/// window server delivers them: the `List`'s table and the row's tap
/// gesture both see the one event. ⌘-click opens a new tab (B-047,
/// Safari's convention) and the clicked row stays selected -- the table's
/// own ⌘-click (toggle the row off) must not win.
@MainActor @Suite(.serialized)
struct LeoSidebarCommandClickTests {
    private static let worker = LeoAgentRow(
        host: .local, name: "worker", template: nil, status: .running, activity: .idle, actionDetail: nil
    )
    private static let settleTimeout = Duration.seconds(3)

    @MainActor private final class Harness {
        let model: LeoSidebarModel
        let window: NSWindow
        let origin = LeoWindowID()
        var attaches: [(LeoAgentRow.ID, LeoWindowID, AttachDisposition)] = []
        var focusRequests: [LeoAgentRow.ID] = []

        init() {
            model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(
                rows: [LeoSidebarCommandClickTests.worker], connectivity: .connected, generation: 1))
            let actions = LeoAgentActions(
                daemon: CommandClickDaemon(), cli: LeoCLI(), model: model,
                hostSelection: .isolatedForTesting(), refresh: {})
            window = NSWindow(
                contentRect: NSRect(x: 120, y: 120, width: 320, height: 480),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: LeoSidebarView(model: model, windowID: origin, actions: actions))
            model.attachRequested = { [unowned self] row, windowID, disposition in
                attaches.append((row.id, windowID, disposition))
            }
            model.focusExistingRequested = { [unowned self] row in focusRequests.append(row.id) }
        }

        var table: NSTableView? { Self.tables(in: window.contentView).first }

        /// The agent's row: the last one, below its section header.
        var agentRowIndex: Int? { table.map { $0.numberOfRows - 1 } }

        func show() async throws {
            window.makeKeyAndOrderFront(nil)
            try await settle { (agentRowIndex ?? -1) >= 0 }
        }

        /// Posts a down/up pair on the agent's row, then waits out the
        /// double-click interval so the next click is a new single click.
        func click(_ modifierFlags: NSEvent.ModifierFlags, until condition: () -> Bool) async throws {
            let table = try #require(table)
            let index = try #require(agentRowIndex)
            let rect = table.rect(ofRow: index)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: modifierFlags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApp.postEvent(event, atStart: false)
            }
            try await settle(condition)
            try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        }

        func settle(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + LeoSidebarCommandClickTests.settleTimeout
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func close() { window.close() }

        private static func tables(in view: NSView?) -> [NSTableView] {
            guard let view else { return [] }
            return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
        }
    }

    @Test func commandClickOnTheSelectedRowOpensANewTabAndKeepsItSelected() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.show()
        let id = Self.worker.id

        try await harness.click([]) { harness.model.selection == id }
        #expect(harness.model.selection == id)
        #expect(harness.attaches.isEmpty, "a plain click on a row with no tab only selects it")

        try await harness.click(.command) { !harness.attaches.isEmpty }

        #expect(harness.attaches.map(\.0) == [id])
        #expect(harness.attaches.first?.1 == harness.origin)
        #expect(harness.attaches.first?.2 == .newTab)
        #expect(harness.focusRequests.isEmpty)
        #expect(harness.model.selection == id, "the list's ⌘-click must not toggle the row off")
        #expect(harness.table?.selectedRow == harness.agentRowIndex, "the row keeps its highlight")
    }

    @Test func commandClickOnAnUnselectedRowSelectsItAndOpensANewTab() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.show()
        let id = Self.worker.id

        try await harness.click(.command) { !harness.attaches.isEmpty }

        #expect(harness.attaches.map(\.0) == [id])
        #expect(harness.attaches.first?.2 == .newTab)
        #expect(harness.model.selection == id)
        #expect(harness.table?.selectedRow == harness.agentRowIndex)
    }
}

private struct CommandClickDaemon: LeoDaemonClient {
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
