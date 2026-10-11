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

    /// The harness agents are idle, so one line: the name line and the row's
    /// padding, with no list inset, come to the `.small` row's 24pt.
    @Test func oneLineAgentRowsKeepTheirHeight() async throws {
        let harness = try await SpacingHarness()
        defer { harness.close() }
        let content = 2 * LeoAgentRowMetrics.verticalPadding + LeoAgentRowMetrics.nameLineHeight
        let expected = content + 2 * LeoDispatchRowMetrics.listVerticalInset

        #expect(abs(expected - 24) < 0.5, "the spec's 24pt one-line row, got \(expected)")
        #expect(abs(harness.table.rect(ofRow: 1).height - expected) < 0.5)
        #expect(abs(harness.table.rect(ofRow: harness.table.numberOfRows - 1).height - expected) < 0.5)
    }

    /// The list sizes rows it hasn't drawn at the table's `rowHeight`. A
    /// one-line row that renders taller grows when first drawn, after the
    /// list has clamped its scroll offset to the old end, and leaves the
    /// bottom short (seen after the last terminal closed).
    @Test func theTablesEstimatedRowHeightIsTheOneLineAgentRowHeight() async throws {
        let harness = try await SpacingHarness()
        defer { harness.close() }
        let rendered = harness.table.rect(ofRow: 1).height

        #expect(abs(harness.table.rowHeight - rendered) < 0.5, "estimated \(harness.table.rowHeight), rendered \(rendered)")
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

    /// Where the content sits, not where the row's bounds are: an enlarged last
    /// row whose content drifted to the middle would keep its height and lose
    /// the contrast.
    @Test func theGroupGapIsClearlyLargerThanTheGapsInsideTheGroup() async throws {
        let harness = try await SpacingHarness()
        defer { harness.close() }
        let content = harness.contentFrames()

        try #require(content.agents.count == 2 && content.dispatches.count == 3, "alpha, its three dispatches, beta: \(content)")
        let agentToFirst = content.dispatches[0].minY - content.agents[0].maxY
        let siblings = zip(content.dispatches, content.dispatches.dropFirst()).map { $1.minY - $0.maxY }
        let lastToNext = content.agents[1].minY - content.dispatches[2].maxY

        for inside in [agentToFirst] + siblings {
            #expect(lastToNext - inside >= LeoDispatchRowMetrics.minimumGroupContrast, "last to next agent \(lastToNext) vs a gap inside the group \(inside)")
        }
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

        // The role glyph starts each dispatch's label: the agent's name
        // column at depth 0, 16pt further in per level.
        let leadingEdges = harness.contentFrames().dispatches.map(\.minX)
        let step = LeoDispatchRowPresentation.indentPerLevel

        #expect(leadingEdges[1] - leadingEdges[0] == step)
        #expect(leadingEdges[2] == leadingEdges[0])
        #expect(leadingEdges[0] == harness.contentFrames().agents[0].minX + LeoAgentRowMetrics.nameColumnInset)
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

    /// The rendered content of the agent rows (their catcher without its
    /// vertical padding) and of the dispatch rows (their label's catcher),
    /// top to bottom, in the table's coordinates. A catcher belongs to the
    /// row it sits in: the first and last rows are the agents.
    func contentFrames() -> (agents: [NSRect], dispatches: [NSRect]) {
        let frames = catcherFrames().sorted { $0.minY < $1.minY }
        let padding = LeoAgentRowMetrics.verticalPadding
        let agentRows = [1, table.numberOfRows - 1]
        let isAgent = { (frame: NSRect) in agentRows.contains(self.table.row(at: NSPoint(x: frame.midX, y: frame.midY))) }
        let agents = frames.filter(isAgent).map { $0.insetBy(dx: 0, dy: padding) }
        let dispatches = frames.filter { !isAgent($0) && $0.width > 100 }
        return (agents, dispatches)
    }

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
        let deadline = ContinuousClock.now + .seconds(5)
        var previous: [NSRect]?
        while ContinuousClock.now < deadline {
            let measured = layout(of: window)
            // Settled: every row and its content measured twice, unchanged.
            if let measured, measured == previous { break }
            previous = measured
            try await Task.sleep(for: .milliseconds(20))
        }
        return try #require(views(NSTableView.self, in: window.contentView).first)
    }

    /// Every row's frame followed by every click catcher's, or nil until the
    /// table has its rows and their content has been laid out.
    private static func layout(of window: NSWindow) -> [NSRect]? {
        guard let table = views(NSTableView.self, in: window.contentView).first, table.numberOfRows >= 6 else { return nil }
        let catchers = views(LeoRowClickCatcherView.self, in: window.contentView).map { $0.convert($0.bounds, to: table) }
        return catchers.count >= 5 ? (0..<table.numberOfRows).map { table.rect(ofRow: $0) } + catchers : nil
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
