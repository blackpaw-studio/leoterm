import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-048: clicks on a sidebar row, through the real list. The clicks are
/// posted to the app's event queue, so they reach the list the way the
/// window server delivers them. The sidebar's window is never key here:
/// another window holds key (or the app is in the background), as when a
/// ⌘-click lands on a background window, which doesn't make it key. That
/// keeps these tests independent of which app is frontmost.
///
/// ⌘-click opens a new tab (B-047, Safari's convention) and the clicked
/// row stays selected -- the table's own ⌘-click (toggle the row off)
/// must not win.
@MainActor @Suite(.serialized)
struct LeoSidebarCommandClickTests {
    private let worker = LeoAgentRow(
        host: .local, name: "worker", template: nil, status: .running, activity: .idle, actionDetail: nil
    )

    @Test func commandClickOnTheSelectedRowOpensANewTabAndKeepsItSelected() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }

        try await harness.clickRow([])
        #expect(harness.model.selection == worker.id)
        #expect(harness.attaches.isEmpty, "a plain click on a row with no tab only selects it")

        try await harness.clickRow(.command)

        #expect(harness.attaches.map(\.0) == [worker.id])
        #expect(harness.attaches.first?.1 == harness.origin)
        #expect(harness.attaches.first?.2 == .newTab)
        #expect(harness.focusRequests.isEmpty)
        #expect(harness.model.selection == worker.id, "the list's ⌘-click must not toggle the row off")
        #expect(harness.table.selectedRow == harness.agentRowIndex, "the row keeps its highlight")
    }

    @Test func commandClickOnAnUnselectedRowSelectsItAndOpensANewTab() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }

        try await harness.clickRow(.command)

        #expect(harness.attaches.map(\.0) == [worker.id])
        #expect(harness.attaches.first?.2 == .newTab)
        #expect(harness.model.selection == worker.id)
        #expect(harness.table.selectedRow == harness.agentRowIndex)
    }

    @Test func plainClickOnARowWithATabFocusesIt() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }
        harness.model.receiveAttachLinks(LeoAttachLinkState(focused: nil, tabCounts: [worker.id: 1]))

        try await harness.clickRow([])

        #expect(harness.focusRequests == [worker.id])
        #expect(harness.attaches.isEmpty)
    }

    @Test func doubleClickOnARowAttachesExactlyOnce() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }

        try await harness.doubleClickRow()

        #expect(harness.attaches.map(\.2) == [.reuseOrTab])
        #expect(harness.focusRequests.isEmpty)
    }

    /// The button is the row's own control: its click is never also a row
    /// click, or a ⌘-click would open two tabs.
    @Test(arguments: [NSEvent.ModifierFlags.command, []])
    func clickingTheAttachButtonAttachesExactlyOnce(modifierFlags: NSEvent.ModifierFlags) async throws {
        let harness = try await CommandClickHarness(row: worker, isSidebarKey: true)
        defer { harness.close() }

        try await harness.clickAttachButton(modifierFlags)

        #expect(harness.attaches.map(\.2) == [.reuseOrTab])
        #expect(harness.focusRequests.isEmpty)
    }

    /// Intended, as in Finder's sidebar: once a row is selected, clicking
    /// empty space keeps it (the list's selection is required, which is
    /// also what stops ⌘-click toggling the row off).
    @Test func clickingEmptySidebarSpaceKeepsTheSelection() async throws {
        let harness = try await CommandClickHarness(row: worker)
        defer { harness.close() }
        try await harness.clickRow([])
        try #require(harness.model.selection == worker.id)

        try await harness.clickEmptySpace()

        #expect(harness.model.selection == worker.id)
        #expect(harness.table.selectedRow == harness.agentRowIndex)
        #expect(harness.attaches.isEmpty)
        #expect(harness.focusRequests.isEmpty)
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
    /// Holds key, so the sidebar's window never has it -- unless the test
    /// needs the sidebar key (SwiftUI's Button acts only in a key window);
    /// then the sidebar's window claims key itself, since activating the
    /// test host isn't in the test's control.
    private let keyWindow: NSWindow
    private let isSidebarKey: Bool
    private var mouseUps = 0
    private var monitor: Any?

    init(row: LeoAgentRow, isSidebarKey: Bool = false) async throws {
        self.isSidebarKey = isSidebarKey
        model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: [row], connectivity: .connected, generation: 1))
        let actions = LeoAgentActions(
            daemon: CommandClickDaemon(), cli: LeoCLI(), model: model,
            hostSelection: .isolatedForTesting(), refresh: {})
        window = isSidebarKey ? AlwaysKeyWindow.make(at: NSPoint(x: 120, y: 120)) : Self.makeWindow(at: NSPoint(x: 120, y: 120))
        keyWindow = Self.makeWindow(at: NSPoint(x: 480, y: 120))
        window.contentView = NSHostingView(rootView: LeoSidebarView(model: model, windowID: origin, actions: actions))
        window.orderFront(nil)
        keyWindow.makeKeyAndOrderFront(nil)
        table = try await Self.settledTable(in: window)
        model.attachRequested = { [weak self] row, windowID, disposition in
            self?.attaches.append((row.id, windowID, disposition))
        }
        model.focusExistingRequested = { [weak self] row in self?.focusRequests.append(row.id) }
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

    /// Hovers the row so its Attach button shows, then clicks the button
    /// where the row's click catcher says it is.
    func clickAttachButton(_ modifierFlags: NSEvent.ModifierFlags) async throws {
        let catcher = try #require(Self.views(LeoRowClickCatcherView.self, in: window.contentView).first)
        try hoverAgentRow()
        try await Self.settle { catcher.excludedRect != nil }
        let button = try #require(catcher.excludedRect, "the hovered row never showed its Attach button")
        let center = catcher.convert(NSPoint(x: button.midX, y: button.midY), to: table)
        try await click(at: center, modifierFlags)
    }

    /// Posted mouse-moved events don't drive tracking areas (AppKit uses the
    /// real cursor), so this enters the row's tracking areas directly.
    private func hoverAgentRow() throws {
        let rowView = try #require(table.rowView(atRow: agentRowIndex, makeIfNecessary: false))
        let rect = table.rect(ofRow: agentRowIndex)
        let location = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let areas = Self.descendants(of: rowView).flatMap(\.trackingAreas)
        try #require(!areas.isEmpty, "the row has no tracking areas to hover")
        for area in areas {
            let enter = try #require(NSEvent.enterExitEvent(
                with: .mouseEntered, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0,
                trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil))
            (area.owner as? NSResponder)?.mouseEntered(with: enter)
        }
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
        guard !isSidebarKey else { return }
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

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }

    private static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        return (view as? View).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }
}

/// Key whether or not the test host is the active app.
private final class AlwaysKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }

    static func make(at origin: NSPoint) -> NSWindow {
        let window = AlwaysKeyWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: 320, height: 480)),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
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
