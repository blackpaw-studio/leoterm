import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// Suites that post to or consume from the process-wide AppKit event queue.
@Suite(.serialized)
struct LeoAppEventQueueTests {
/// B-048: clicks on a sidebar row, through the real list. The clicks are
/// posted to the app's event queue, so they reach the list the way the
/// window server delivers them. The sidebar's window is never key here:
/// another window holds key (or the app is in the background), as when a
/// ⌘-click lands on a background window, which doesn't make it key. That
/// keeps these tests independent of which app is frontmost.
///
/// ⌘-click opens a new window (D-104) and the clicked
/// row stays selected -- the table's own ⌘-click (toggle the row off)
/// must not win.
@MainActor @Suite
struct LeoSidebarCommandClickTests {
    private let worker = LeoAgentRow(
        host: .local, name: "worker", template: nil, status: .running, activity: .idle, actionDetail: nil
    )

    @Test func commandClickOnTheSelectedRowOpensANewWindowAndKeepsItSelected() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }

        harness.model.receiveAttachLinks(LeoAttachLinkState(focused: nil, attachCounts: [worker.id: 1]))
        try await harness.clickRow([])
        #expect(harness.model.selection == worker.id)
        #expect(harness.focusRequests == [worker.id], "a plain click on a row shown in a window goes to that window")

        try await harness.clickRow(.command)

        #expect(harness.attaches.map(\.0) == [worker.id])
        #expect(harness.attaches.first?.1 == harness.origin)
        #expect(harness.attaches.first?.2 == .newWindow)
        #expect(harness.focusRequests == [worker.id])
        #expect(harness.model.selection == worker.id, "the list's ⌘-click must not toggle the row off")
        #expect(harness.table.selectedRow == harness.agentRowIndex, "the row keeps its highlight")
    }

    @Test func commandClickOnAnUnselectedRowSelectsItAndOpensANewWindow() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }

        try await harness.clickRow(.command)

        #expect(harness.attaches.map(\.0) == [worker.id])
        #expect(harness.attaches.first?.2 == .newWindow)
        #expect(harness.model.selection == worker.id)
        #expect(harness.table.selectedRow == harness.agentRowIndex)
    }

    @Test func plainClickOnARowWithALiveAttachFocusesIt() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }
        harness.model.receiveAttachLinks(LeoAttachLinkState(focused: nil, attachCounts: [worker.id: 1]))

        try await harness.clickRow([])

        #expect(harness.focusRequests == [worker.id])
        #expect(harness.attaches.isEmpty)
    }

    @Test func doubleClickOnARowAttachesExactlyOnce() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }

        try await harness.doubleClickRow()

        #expect(harness.attaches.map(\.2) == [.content])
        #expect(harness.focusRequests.isEmpty)
    }

    /// B-049: the row is the target -- one click attaches, with no
    /// button to aim for.
    @Test func plainClickOnARowWithoutALiveAttachAttachesExactlyOnce() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }

        try await harness.clickRow([])

        #expect(harness.attaches.map(\.0) == [worker.id])
        #expect(harness.attaches.first?.1 == harness.origin)
        #expect(harness.attaches.first?.2 == .content)
        #expect(harness.focusRequests.isEmpty)
        #expect(harness.model.selection == worker.id)
    }

    /// Intended, as in Finder's sidebar: once a row is selected, clicking
    /// empty space keeps it (the list's selection is required, which is
    /// also what stops ⌘-click toggling the row off).
    @Test func clickingEmptySidebarSpaceKeepsTheSelection() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }
        try await harness.clickRow([])
        try #require(harness.model.selection == worker.id)
        let attachesBefore = harness.attaches.count

        try await harness.clickEmptySpace()

        #expect(harness.model.selection == worker.id)
        #expect(harness.table.selectedRow == harness.agentRowIndex)
        #expect(harness.attaches.count == attachesBefore, "empty space is not a row click")
        #expect(harness.focusRequests.isEmpty)
    }
}
}

// MARK: - Harness

@MainActor private final class CommandClickHarness {
    let model: LeoSidebarModel
    let window: NSWindow
    let table: NSTableView
    let origin = LeoWindowID()
    private(set) var attaches: [(LeoAgentRow.ID, LeoWindowID, AttachDisposition)] = []
    private(set) var focusRequests: [LeoAgentRow.ID] = []
    /// Holds key, so the sidebar's window never has it.
    private let keyWindow: NSWindow
    private var mouseUps = 0
    private var monitor: Any?

    init(row: LeoAgentRow) async throws {
        model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [row], connectivity: .connected, generation: 1))
        let actions = LeoAgentActions(
            daemon: CommandClickDaemon(), cli: .recordingForTests(), model: model,
            hostSelection: .isolatedForTesting(), processRunner: LeoRecordingTemplateRunner(), refresh: {})
        window = Self.makeWindow(at: NSPoint(x: 120, y: 120))
        keyWindow = Self.makeWindow(at: NSPoint(x: 480, y: 120))
        window.contentView = NSHostingView(rootView: LeoSidebarView(model: model, windowID: origin, actions: actions, terminals: LeoWindowTerminals()))
        window.orderFront(nil)
        keyWindow.makeKeyAndOrderFront(nil)
        table = try await Self.settledTable(in: window)
        model.attachRequested = { [weak self] row, windowID, disposition in
            self?.attaches.append((row.id, windowID, disposition))
        }
        model.focusExistingRequested = { [weak self] row, _ in self?.focusRequests.append(row.id) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if let self, event.window === window { mouseUps += 1 }
            return event
        }
    }

    /// The agent's row: the last one, below its section header.
    var agentRowIndex: Int { table.numberOfRows - 1 }

    func clickRow(_ modifierFlags: NSEvent.ModifierFlags) async throws {
        let rect = table.rect(ofRow: agentRowIndex)
        try await click(at: NSPoint(x: rect.midX, y: rect.midY), modifierFlags)
    }

    func doubleClickRow(_ modifierFlags: NSEvent.ModifierFlags = []) async throws {
        let rect = table.rect(ofRow: agentRowIndex)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        try await click(at: center, modifierFlags, clickCount: 1, waitsOutDoubleClick: false)
        try await click(at: center, modifierFlags, clickCount: 2)
    }

    func clickEmptySpace() async throws {
        let rect = table.rect(ofRow: agentRowIndex)
        let below = NSPoint(x: rect.midX, y: rect.maxY + 40)
        try #require(table.row(at: below) == -1 && table.visibleRect.contains(below), "no empty space below the rows")
        try await click(at: below, [])
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        window.close()
        keyWindow.close()
    }

    /// Posts a down/up pair at `point` (table coordinates), waits until the
    /// up has been dispatched, then (by default) waits out the double-click
    /// interval so the next click is a new single click.
    private func click(
        at point: NSPoint, _ modifierFlags: NSEvent.ModifierFlags,
        clickCount: Int = 1, waitsOutDoubleClick: Bool = true
    ) async throws {
        try await holdKey()
        let location = table.convert(point, to: nil)
        let expectedUps = mouseUps + 1
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
            NSApp.postEvent(event, atStart: false)
        }
        try await Self.settle { mouseUps >= expectedUps }
        try #require(mouseUps >= expectedUps, "the posted click was never dispatched")
        if waitsOutDoubleClick { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1)) }
    }

    /// A plain click makes the sidebar's window key; take it back.
    private func holdKey() async throws {
        keyWindow.makeKeyAndOrderFront(nil)
        try #require(!window.isKeyWindow, "the sidebar's window must not be key")
    }

    private static func makeWindow(at origin: NSPoint) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 320, height: 480)),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func settledTable(in window: NSWindow) async throws -> NSTableView {
        try await settle { tables(in: window.contentView).first.map { $0.numberOfRows > 0 } ?? false }
        return try #require(tables(in: window.contentView).first)
    }

    private static func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func tables(in view: NSView?) -> [NSTableView] { views(NSTableView.self, in: view) }

    private static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        return (view as? View).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
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
