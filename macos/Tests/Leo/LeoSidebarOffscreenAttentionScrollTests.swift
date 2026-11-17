import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-413: the edge indicators over the real sidebar list. 40 agents in a
/// 320×480 window never all fit, so rows sit above or below what shows. The
/// window is shown but never made key; turns of the main run loop are
/// counted, never waited on.
@MainActor @Suite(.serialized)
struct LeoSidebarOffscreenAttentionScrollTests {
    private static let agentCount = 40
    private static let top = "leo.sidebar.offscreenAttention.top"
    private static let bottom = "leo.sidebar.offscreenAttention.bottom"
    private static let settleTurns = 12

    // MARK: Which edge

    @Test func anUnreadRowBelowTheFoldShowsOnlyTheBottomIndicator() async throws {
        let sidebar = try await Sidebar.make(unread: ["agent-39": 2])
        defer { sidebar.close() }

        try #require(await sidebar.waits { sidebar.indicator(Self.bottom) != nil }, Comment(rawValue: "the bottom indicator shows; \(sidebar.diagnostics())"))
        #expect(sidebar.indicator(Self.top) == nil)
    }

    @Test func scrollingDownPastANeedsYouRowShowsTheTopIndicator() async throws {
        let sidebar = try await Sidebar.make(states: ["agent-0": .needsInput])
        defer { sidebar.close() }
        await sidebar.settle()
        try #require(sidebar.indicator(Self.top) == nil, "agent-0 is in view at the top")

        sidebar.scroll(toRow: 20)

        try #require(await sidebar.waits { sidebar.indicator(Self.top) != nil }, "the top indicator shows")
        #expect(sidebar.indicator(Self.bottom) == nil)
    }

    @Test func bothIndicatorsShowWhenRowsAreOffBothEdges() async throws {
        let sidebar = try await Sidebar.make(states: ["agent-0": .errored], unread: ["agent-39": 1])
        defer { sidebar.close() }

        sidebar.scroll(toRow: 20)

        try #require(await sidebar.waits { sidebar.indicator(Self.top) != nil && sidebar.indicator(Self.bottom) != nil })
        // Scrolling the top one back into view leaves the bottom one.
        sidebar.scroll(toRow: 0)
        try #require(await sidebar.waits { sidebar.indicator(Self.top) == nil }, "the top indicator goes")
        #expect(sidebar.indicator(Self.bottom) != nil)
    }

    // MARK: Press

    @Test func pressingTheIndicatorScrollsTheNearestRowIntoViewAndHidesIt() async throws {
        let sidebar = try await Sidebar.make(unread: ["agent-30": 1, "agent-39": 1])
        defer { sidebar.close() }
        try #require(await sidebar.waits { sidebar.indicator(Self.bottom) != nil })
        let element = try #require(sidebar.indicator(Self.bottom))
        #expect(element.accessibilityRole() == .button, "VoiceOver reaches it as a button")
        #expect(element.accessibilityLabel() == "Scroll down to agent-30, 1 unread message")

        #expect(element.accessibilityPerformPress(), "the button accepts a press")

        // agent-30 is in view; the indicator now points at the one still below.
        try #require(
            await sidebar.waits { sidebar.indicator(Self.bottom)?.accessibilityLabel() == "Scroll down to agent-39, 1 unread message" },
            Comment(rawValue: "the indicator moves on to agent-39; \(sidebar.diagnostics())")
        )
        let viewport = try #require(LeoSidebarViewportTracker.viewport(of: sidebar.scrollView))
        // Rows: 0 header, 1 Running title, 2-21 running, 22 Stopped title, 23… stopped.
        #expect(viewport.visibleRows.contains(Sidebar.tableRow(ofAgent: 30)), "agent-30 is on screen")
        #expect(sidebar.indicator(Self.top) == nil)

        #expect(sidebar.indicator(Self.bottom)?.accessibilityPerformPress() == true)

        #expect(await sidebar.waits { sidebar.indicator(Self.bottom) == nil }, "the indicator goes once the last row is in view")
    }

    // MARK: Clearing

    @Test func clearingTheUnreadOrTheStateHidesTheIndicator() async throws {
        let sidebar = try await Sidebar.make(states: ["agent-0": .needsInput], unread: ["agent-39": 1])
        defer { sidebar.close() }
        sidebar.scroll(toRow: 20)
        try #require(await sidebar.waits { sidebar.indicator(Self.top) != nil && sidebar.indicator(Self.bottom) != nil })

        sidebar.clearUnread("agent-39")
        try #require(await sidebar.waits { sidebar.indicator(Self.bottom) == nil }, "reading the chat hides the bottom one")

        sidebar.receive(states: ["agent-0": .working])
        #expect(await sidebar.waits { sidebar.indicator(Self.top) == nil }, "the agent no longer needing you hides the top one")
    }

    @Test(arguments: [LeoAttentionBadge.working, .finished])
    func workingFinishedAndIdleRowsNeverShowAnIndicator(_ badge: LeoAttentionBadge) async throws {
        let states = Dictionary(uniqueKeysWithValues: [0, 1, 38, 39].map { ("agent-\($0)", badge) })
        let sidebar = try await Sidebar.make(states: states)
        defer { sidebar.close() }

        sidebar.scroll(toRow: 20)
        await sidebar.settle()

        #expect(sidebar.indicator(Self.top) == nil)
        #expect(sidebar.indicator(Self.bottom) == nil)
    }

    // MARK: The mirrored index

    /// Dispatch rows under an agent push the rows below it down; a collapsed
    /// group has none. The indicator follows the real row: shown while it is
    /// a row below the edge, gone once it is the last in view.
    @Test func theMirroredIndexIsTheRowTheListDraws() async throws {
        let sidebar = try await Sidebar.make(unread: ["agent-19": 1], dispatchesUnder: "agent-1", collapsed: ["stopped"])
        defer { sidebar.close() }
        // 0 header, 1 title, 2-21 agents (agent-1 has 3 dispatch rows under it).
        let row = Sidebar.tableRow(ofAgent: 19, dispatches: 3)
        // Selecting a row names its table row; the list takes the selection once the row is drawn.
        sidebar.scroll(toRow: row)
        sidebar.model.userSelected(LeoAgentID(host: .local, name: "agent-19"))
        try #require(await sidebar.waits { sidebar.table.selectedRow >= 0 }, "the list selects agent-19")
        try #require(sidebar.table.selectedRow == row, "the list draws agent-19 at row \(row)")

        // Row `row` is the first one below the edge.
        sidebar.scroll(toRow: 0)
        let height = sidebar.table.visibleRect.height
        sidebar.scrollTo(y: sidebar.table.rect(ofRow: row).minY - height)
        try #require(await sidebar.waits { sidebar.indicator(Self.bottom) != nil }, "agent-19 is below the edge")

        // Row `row` is wholly in view at the bottom edge.
        sidebar.scrollTo(y: sidebar.table.rect(ofRow: row).maxY - height)
        #expect(await sidebar.waits { sidebar.indicator(Self.bottom) == nil }, "agent-19 is in view")
    }
}

// MARK: - Harness

@MainActor private final class Sidebar {
    let window: NSWindow
    let model: LeoSidebarModel
    let unread: LeoChatUnreadStore
    private let agentCount = 40
    private let chat = FakeChatClient()

    /// The window's list, whichever table it is now.
    var table: NSTableView { Self.tables(in: window.contentView).first ?? NSTableView() }
    var scrollView: NSScrollView { table.enclosingScrollView ?? NSScrollView() }

    /// `states` badges agents by name; `unread` gives counts by name (via
    /// live chat messages, as the store counts them); dispatch rows go under
    /// `dispatchesUnder`; `collapsed` are section ids.
    static func make(
        states: [String: LeoAttentionBadge] = [:], unread: [String: Int] = [:],
        dispatchesUnder: String? = nil, collapsed: [String] = []
    ) async throws -> Sidebar {
        let sidebar = Sidebar(states: states, unread: unread, dispatchesUnder: dispatchesUnder, collapsed: collapsed)
        try await sidebar.settledTable(moreThan: collapsed.isEmpty ? 40 : 20)
        return sidebar
    }

    private init(states: [String: LeoAttentionBadge], unread counts: [String: Int], dispatchesUnder: String?, collapsed: [String]) {
        let children = dispatchesUnder.map { [$0: (1 ... 3).map(Self.node)] } ?? [:]
        model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(
            rows: Self.agents(count: agentCount, states: states), connectivity: .connected, generation: 1,
            dispatchChildren: children, features: LeoDaemonFeatures(["dispatch_tree"]), featuresHost: .local
        ))
        for id in collapsed { model.toggleCollapsed(id, host: .local) }
        unread = LeoChatUnreadStore()
        unread.bind(chat, host: .local)
        var serial = 0
        for (name, count) in counts {
            for _ in 0 ..< count {
                serial += 1
                unread.receive(
                    LeoChatFeedDelivery(host: .local, signal: .event(.message(chatMessage("m\(serial)", agent: name, at: serial)))),
                    isOnScreen: { _ in false }
                )
            }
        }
        let actions = LeoAgentActions(
            clients: FakeMachineClients(daemon: OffscreenTestDaemon()), cli: .recordingForTests(), model: model,
            processRunner: LeoRecordingTemplateRunner(), refresh: {}
        )
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LeoSidebarView(model: model, windowID: LeoWindowID(), actions: actions, terminals: LeoWindowTerminals(), unread: unread)
        )
        window.orderFront(nil)
    }

    func close() { window.close() }

    // MARK: Driving

    func receive(states: [String: LeoAttentionBadge]) {
        model.receive(
            LeoSidebarSnapshot(
                rows: Self.agents(count: agentCount, states: states), connectivity: .connected, generation: 2,
                features: LeoDaemonFeatures(["dispatch_tree"]), featuresHost: .local
            ), for: .local
        )
    }

    func clearUnread(_ name: String) { unread.clear(LeoAgentID(host: .local, name: name)) }

    func scroll(toRow row: Int) { scrollTo(y: table.rect(ofRow: row).minY) }

    func scrollTo(y: CGFloat) { table.scroll(NSPoint(x: table.visibleRect.minX, y: y)) }

    // MARK: Waiting (turns of the run loop, never time)

    func settle(turns: Int = 12) async {
        for _ in 0 ..< turns { await nextTurn() }
    }

    func waits(limit: Int = 100, _ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< limit {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            if condition() { return true }
            await nextTurn()
        }
        return condition()
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func settledTable(moreThan rows: Int) async throws {
        let filled = await waits(limit: 200) { Self.tables(in: window.contentView).first.map { $0.numberOfRows > rows } ?? false }
        try #require(filled, "the list fills")
    }

    // MARK: Looking

    func diagnostics() -> String {
        let viewport = LeoSidebarViewportTracker.viewport(of: scrollView).map { "\($0.visibleRows) of \($0.numberOfRows)" } ?? "none"
        return "viewport: \(viewport)"
    }

    /// The indicator with `identifier`, found in the view tree as VoiceOver
    /// reaches it: an accessibility element of the window's content.
    func indicator(_ identifier: String) -> LeoOffscreenAttentionPillView? {
        Self.pills(in: window.contentView).first { $0.accessibilityIdentifier() == identifier }
    }

    private static func pills(in view: NSView?) -> [LeoOffscreenAttentionPillView] {
        guard let view else { return [] }
        return (view as? LeoOffscreenAttentionPillView).map { [$0] } ?? view.subviews.flatMap { pills(in: $0) }
    }

    private static func tables(in view: NSView?) -> [NSTableView] {
        guard let view else { return [] }
        return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    /// Table row of `agent-n` in the default layout: the machine's header,
    /// the Running title, then the agents (the first half run, in name order
    /// of the daemon's list); `dispatches` rows sit under agent-1.
    static func tableRow(ofAgent index: Int, dispatches: Int = 0) -> Int {
        let isRunning = index < 20
        return isRunning ? 2 + index + (index > 1 ? dispatches : 0) : 3 + index + dispatches
    }

    private static func agents(count: Int, states: [String: LeoAttentionBadge]) -> [LeoAgentRow] {
        (0 ..< count).map { index in
            let name = "agent-\(index)"
            return LeoAgentRow(
                host: .local, name: name, template: nil, status: index < count / 2 ? .running : .stopped,
                activity: .idle, actionDetail: nil, attention: states[name]
            )
        }
    }

    private static func node(_ number: Int) -> LeoDispatchNode {
        LeoDispatchNode(dispatch: LeoDispatch(id: "d\(number)", name: "d\(number)", role: "plan", status: "running"), depth: 0)
    }
}

private struct OffscreenTestDaemon: LeoDaemonClient {
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
