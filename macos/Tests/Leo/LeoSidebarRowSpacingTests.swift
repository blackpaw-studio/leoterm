import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-275: the sidebar's row rhythm, measured on the real list in a window.
@MainActor @Suite(.serialized)
struct LeoSidebarRowSpacingTests {
    /// Header, alpha, its three dispatches, then (once there is one) the gap
    /// row, then beta.
    private static let firstDispatchRow = 2
    private static let lastDispatchRow = 4

    @Test func dispatchRowsSitAtMost24ptApart() async throws {
        let harness = try await SpacingHarness()
        defer { harness.close() }

        let tops = (Self.firstDispatchRow...Self.lastDispatchRow).map { harness.table.rect(ofRow: $0).minY }

        for (above, below) in zip(tops, tops.dropFirst()) {
            #expect(below - above <= 24, "dispatch rows must sit at most 24pt apart, got \(below - above)")
        }
    }

    @Test func agentRowsKeepTheirHeight() async throws {
        let harness = try await SpacingHarness()
        defer { harness.close() }
        let content = 2 * LeoAgentRowMetrics.verticalPadding + LeoAgentRowMetrics.nameLineHeight
            + LeoAgentRowMetrics.lineSpacing + LeoAgentRowMetrics.detailLineHeight
        let expected = content + 2 * LeoDispatchRowMetrics.listVerticalInset

        #expect(abs(harness.table.rect(ofRow: 1).height - expected) < 0.5)
        #expect(abs(harness.table.rect(ofRow: harness.table.numberOfRows - 1).height - expected) < 0.5)
    }

    @Test func theLastDispatchCarriesTheGapBelowItsGroup() async throws {
        let harness = try await SpacingHarness()
        defer { harness.close() }
        let table = harness.table

        try #require(table.numberOfRows == 6, "header, alpha, three dispatches, beta")
        let last = table.rect(ofRow: Self.lastDispatchRow)
        #expect(abs(last.height - (LeoDispatchRowMetrics.pitch + LeoDispatchRowMetrics.groupGap)) < 0.5, "rows: \((0..<table.numberOfRows).map { table.rect(ofRow: $0) })")
        #expect(abs(table.rect(ofRow: 5).minY - last.maxY) < 0.5, "beta follows directly")
    }

    @Test func terminalRowsKeepTheirHeight() async throws {
        let terminals = LeoWindowTerminals()
        terminals.add(UUID(), title: "Terminal")
        let harness = try await SpacingHarness(terminals: terminals)
        defer { harness.close() }
        let table = harness.table

        #expect(abs(table.rect(ofRow: table.numberOfRows - 1).height - LeoDispatchRowMetrics.terminalRowHeight) < 0.5)
        #expect(abs(table.rect(ofRow: table.numberOfRows - 2).height - 19) < 0.5, "the Terminals header keeps its 19pt")
    }

    @Test func dispatchContentKeepsItsLeadingEdge() async throws {
        let harness = try await SpacingHarness()
        defer { harness.close() }

        // The role chip is the first catcher at each dispatch's own depth.
        let leadingEdges = harness.catcherFrames().filter { $0.height < 20 && $0.width > 100 }.map(\.minX)

        // Measured before the change: depth 0 at 28pt, depth 1 at 40pt.
        #expect(leadingEdges == [28, 40, 28])
    }
}

// MARK: - Harness

@MainActor final class SpacingHarness {
    static let attachableFeatures = LeoDaemonFeatures(["dispatch_tree", "dispatch_attach"])
    let window: NSWindow
    let table: NSTableView

    init(terminals: LeoWindowTerminals? = nil) async throws {
        let alpha = Self.agent("alpha")
        let beta = Self.agent("beta")
        let snapshot = LeoSidebarSnapshot(
            rows: [alpha, beta], connectivity: .connected, generation: 1,
            dispatchChildren: ["alpha": [
                Self.node("d1", role: "plan", depth: 0),
                Self.node("d2", role: "implement.hard", depth: 1),
                Self.node("d3", role: "review.concurrency", depth: 0),
            ]],
            features: Self.attachableFeatures, featuresHost: .local)
        let model = LeoSidebarModel(snapshot: snapshot)
        let actions = LeoAgentActions(
            daemon: SpacingDaemon(), cli: .recordingForTests(), model: model,
            hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LeoSidebarView(
            model: model, windowID: LeoWindowID(), actions: actions, terminals: terminals ?? LeoWindowTerminals()))
        window.orderFront(nil)
        table = try await Self.settledTable(in: window)
    }

    func close() { window.close() }

    func catcherFrames() -> [NSRect] {
        Self.views(LeoRowClickCatcherView.self, in: window.contentView).map { $0.convert($0.bounds, to: table) }
    }

    private static func agent(_ name: String) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: nil, status: .running, activity: .idle, actionDetail: nil)
    }

    private static func node(_ id: String, role: String, depth: Int) -> LeoDispatchNode {
        LeoDispatchNode(
            dispatch: LeoDispatch(id: id, name: id, role: role, status: "running", attachable: true), depth: depth)
    }

    private static func settledTable(in window: NSWindow) async throws -> NSTableView {
        let deadline = ContinuousClock.now + .seconds(3)
        func ready() -> Bool { views(NSTableView.self, in: window.contentView).first.map { $0.numberOfRows >= 6 } ?? false }
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let table = try #require(views(NSTableView.self, in: window.contentView).first)
        // Let the row views lay out.
        try await Task.sleep(for: .milliseconds(200))
        return table
    }

    static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        return (view as? View).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }
}

private struct SpacingDaemon: LeoDaemonClient {
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
