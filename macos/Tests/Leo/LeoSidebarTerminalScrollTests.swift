import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-057: the Terminals section sits below every agent, so a terminal row
/// the window selects -- a new one ⌘T just added, or one it switched to --
/// is scrolled into view, through the real list. The sidebar's window is
/// shown but never made key.
@MainActor @Suite(.serialized)
struct LeoSidebarTerminalScrollTests {
    private static let agentCount = 40

    @Test(arguments: ["a new row", "a listed row"])
    func aSelectedTerminalRowBelowManyAgentsIsScrolledIntoView(_ selected: String) async throws {
        let terminals = LeoWindowTerminals()
        let listed = UUID()
        if selected == "a listed row" { terminals.add(listed, title: "Terminal") }
        let window = try makeWindow(terminals: terminals)
        defer { window.close() }
        let table = try await settledTable(in: window)
        let rowsBefore = table.numberOfRows
        try #require(!isVisible(row: rowsBefore - 1, in: table), "the list starts scrolled to its top")

        if selected == "a new row" {
            // As ⌘T does: added and selected in the same turn.
            let id = UUID()
            terminals.add(id, title: "Terminal")
            terminals.select(id)
        } else {
            terminals.select(listed)
        }

        _ = await eventually { table.numberOfRows > rowsBefore || selected == "a listed row" }
        let row = table.numberOfRows - 1
        #expect(await eventually { isVisible(row: row, in: table) }, "the selected terminal row is on screen")
    }

    private func makeWindow(terminals: LeoWindowTerminals) throws -> NSWindow {
        let agents = (0 ..< Self.agentCount).map {
            LeoAgentRow(host: .local, name: "agent-\($0)", template: nil, status: .running, activity: .idle, actionDetail: nil)
        }
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: agents, connectivity: .connected, generation: 1))
        let actions = LeoAgentActions(
            daemon: ScrollTestDaemon(), cli: LeoCLI(), model: model, hostSelection: .isolatedForTesting(), refresh: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 320, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LeoSidebarView(model: model, windowID: LeoWindowID(), actions: actions, terminals: terminals)
        )
        window.orderFront(nil)
        return window
    }

    /// The row's middle is within what the list's scroll view shows.
    private func isVisible(row: Int, in table: NSTableView) -> Bool {
        guard row >= 0, row < table.numberOfRows else { return false }
        let rect = table.rect(ofRow: row)
        return table.visibleRect.contains(NSPoint(x: rect.midX, y: rect.midY))
    }

    private func settledTable(in window: NSWindow) async throws -> NSTableView {
        _ = await eventually { tables(in: window.contentView).first.map { $0.numberOfRows > Self.agentCount } ?? false }
        return try #require(tables(in: window.contentView).first)
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func tables(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }
}

private struct ScrollTestDaemon: LeoDaemonClient {
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
