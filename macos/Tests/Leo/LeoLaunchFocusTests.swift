import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-075: the sidebar's search field took keyboard focus when a window was
/// first shown. AppKit makes the first view of the key view loop first
/// responder when a window without an `initialFirstResponder` goes on
/// screen, and the start screen has nothing focusable, so the search field
/// at the sidebar's top-left won. Mail, Finder and Notes never start in
/// their search field; ⌥⌘F (Agents ▸ Find Agent…) is how you get there.
///
/// Each test builds the launch window the way the app does (a real
/// start-screen `TerminalController` with its sidebar showing) and orders
/// it on screen, which is when AppKit picks. The windows are never made
/// key: suites run in parallel in one app, and a key window takes focus
/// from `GhosttyAttachContentHostFocusTests`. Where a test needs the
/// window to have become key, it delivers `windowDidBecomeKey` itself.
///
/// Needs the test host's `Ghostty.App` and `LeoRuntime`; either missing
/// fails the test rather than passing it silently.
@MainActor @Suite(.serialized)
struct LeoLaunchFocusTests {
    /// The start screen has nothing to focus, so the window itself keeps
    /// the first responder -- as a Finder window with no selection does.
    @Test func theLaunchStartScreenLeavesTheSearchFieldUnfocused() async throws {
        let fixture = try await LaunchWindowFixture.make()
        defer { fixture.close() }
        let field = try await fixture.waitForSearchField()

        #expect(
            fixture.window.firstResponder === fixture.window,
            "first responder on launch: \(fixture.describeFirstResponder())"
        )
        #expect(!fixture.hasFocus(field), "the search field took focus on launch")
        #expect(!fixture.window.isKeyWindow, "the test's window took key status")
    }

    /// Keyboard-first: leaving the first pick to the content area must not
    /// cost the key view loop AppKit builds with that pick, so Tab from the
    /// start screen still reaches the search field, and Tab out of the
    /// field still reaches the agent list.
    ///
    /// B-101: in launch order. `showWindow` makes the window key as it
    /// orders it in, so the loop's rebuild is queued before anything waits
    /// for the sidebar, and runs on the next turn: the search field must be
    /// in the loop by then, or Tab misses it until the window is next key.
    /// The app presents a turn after making the window, which SwiftUI may
    /// or may not have used to build the sidebar; `.immediately` is that
    /// turn's worst case, nothing built yet.
    @Test(arguments: Presentation.allCases)
    func tabFromTheStartScreenReachesTheSearchFieldThenTheListInLaunchOrder(
        _ presentation: Presentation
    ) async throws {
        let fixture = try await LaunchWindowFixture.make(presentation, becomingKey: true)
        defer { fixture.close() }
        await nextMainTurn()

        let field = try #require(fixture.searchField, "the search field doesn't exist after the rebuild turn")
        #expect(field.nextValidKeyView is NSTableView, "after the field: \(String(describing: field.nextValidKeyView))")
        fixture.window.selectNextKeyView(nil)
        #expect(fixture.hasFocus(field), "Tab from the start screen: \(fixture.describeFirstResponder())")
        #expect(!fixture.window.isKeyWindow, "the test's window took key status")
    }

    /// B-157: Tab walks what is on screen after a sidebar or pane is toggled
    /// while the window stays key, without the loop being rebuilt. The loop
    /// is built (sidebar hidden) before the toggle and keeps the collapsed
    /// panes' views, which `nextValidKeyView` skips while they are hidden,
    /// so showing one needs no rebuild.
    @Test func tabReachesTheSearchFieldOfASidebarShownWhileTheWindowStaysKey() async throws {
        let fixture = try await LaunchWindowFixture.make(becomingKey: true, sidebarVisible: false)
        defer { fixture.close() }
        await nextMainTurn()

        fixture.session.setSidebarVisible(true)
        let field = try await fixture.waitForSearchField()
        let reached = await fixture.waitUntil { fixture.tabReaches(field) }
        #expect(reached, "Tab after showing the sidebar: \(fixture.describeFirstResponder())")
        #expect(field.nextValidKeyView is NSTableView, "after the field: \(String(describing: field.nextValidKeyView))")
    }

    /// Same for a side pane: the browser's outline is in the loop once the
    /// pane is shown, and Tab can't land on it once it is hidden again.
    @Test func tabReachesAPaneShownWhileTheWindowStaysKeyAndNotOnceItIsHidden() async throws {
        let fixture = try await LaunchWindowFixture.make(becomingKey: true)
        defer { fixture.close() }
        _ = try await fixture.waitForSearchField()
        await nextMainTurn()
        let pane = try #require(fixture.browserPaneItem, "the split has no browser pane")
        let outline = try #require(fixture.browserOutline, "the browser pane has no outline")

        pane.isCollapsed = false
        let shown = await fixture.waitUntil { fixture.tabReaches(outline) }
        #expect(shown, "Tab after showing the browser pane never reached its outline")

        pane.isCollapsed = true
        let hidden = await fixture.waitUntil { !fixture.tabReaches(outline) }
        #expect(hidden, "Tab after hiding the browser pane still reached its outline")
    }

    /// When the window goes on screen after it is made.
    enum Presentation: CaseIterable, Sendable {
        /// On the next turn, from a plain main-queue block, as
        /// `leoNewPlaceholderWindow` presents it.
        case nextTurn
        /// At once, before SwiftUI has built any of its content.
        case immediately
    }

    // B-101: that a row shown from the start screen hands focus to its
    // terminal is `LeoContentFocusTests.aRowSwitchFocusesTheShownTerminal`.
}

@MainActor
private func nextMainTurn() async {
    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
}

/// A launch window: a start-screen `TerminalController` with its sidebar
/// showing, ordered on screen (never key).
@MainActor
private struct LaunchWindowFixture {
    let controller: TerminalController
    let window: NSWindow

    /// The sidebar's search field, if the split view has built it yet.
    var searchField: NSTextField? { window.contentView.flatMap(Self.findSearchField) }

    /// True while `field` is being edited (its field editor is the
    /// window's first responder).
    func hasFocus(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor() else { return window.firstResponder === field }
        return window.firstResponder === editor
    }

    func describeFirstResponder() -> String {
        guard let responder = window.firstResponder else { return "nil" }
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            return "a field editor for \(String(describing: editor.delegate))"
        }
        return "\(type(of: responder))"
    }

    /// The most main-queue turns `waitForSearchField` lets SwiftUI take.
    static let searchFieldTurnLimit = 200

    /// The sidebar's search field, once the split view has built it. Counts
    /// run-loop turns rather than wall-clock time (D-178, D-254): the field
    /// appears after however many turns SwiftUI needs, however slow the host.
    func waitForSearchField(turnLimit: Int = searchFieldTurnLimit) async throws -> NSTextField {
        for _ in 0 ..< turnLimit {
            if let field = searchField { return field }
            window.contentView?.layoutSubtreeIfNeeded()
            await nextMainTurn()
        }
        throw FixtureError.noSearchField
    }

    var session: LeoWindowSession { controller.leoSession! }

    /// The window's split controller, found from its split view.
    var splitController: LeoSplitViewController? {
        window.contentView.flatMap(Self.findSplitView).flatMap { $0.delegate as? LeoSplitViewController }
    }

    var browserPaneItem: NSSplitViewItem? {
        splitController?.splitViewItems.first {
            ($0.viewController as? LeoRowPaneContainerViewController)?.role == .browser
        }
    }

    var browserOutline: NSView? {
        browserPaneItem.flatMap { Self.findView(in: $0.viewController.view) { $0 is LeoWorkspaceOutlineView } }
    }

    /// True if Tab from the window's own first responder -- the start
    /// screen -- walks the loop to `view` within a loop's length.
    func tabReaches(_ view: NSView) -> Bool {
        var current: NSView? = window.contentView
        for _ in 0 ..< 200 {
            current = current?.nextValidKeyView
            if current === view { return true }
            if current == nil || current === window.contentView { return false }
        }
        return false
    }

    /// Waits on run-loop turns (D-178, D-254) until `condition` holds.
    func waitUntil(turnLimit: Int = searchFieldTurnLimit, _ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< turnLimit {
            if condition() { return true }
            window.contentView?.layoutSubtreeIfNeeded()
            await nextMainTurn()
        }
        return condition()
    }

    func close() {
        controller.closeTabImmediately(registerRedo: false)
    }

    /// `becomingKey` delivers what `makeKeyAndOrderFront` does as it
    /// returns -- the window's did-become-key, in the same turn as the
    /// order-in -- without taking key status from the other suites.
    static func make(
        _ presentation: LeoLaunchFocusTests.Presentation = .nextTurn, becomingKey: Bool = false, sidebarVisible: Bool = true
    ) async throws -> LaunchWindowFixture {
        try #require((NSApp.delegate as? AppDelegate)?.leoRuntime != nil, "the test host has no LeoRuntime")
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty, "the test host has no Ghostty.App")
        try #require(ghostty.readiness == .ready, "the test host's Ghostty.App isn't ready")
        let controller = TerminalController(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        guard let window = controller.window, let session = controller.leoSession else {
            controller.closeTabImmediately(registerRedo: false)
            throw FixtureError.noLeoWindow
        }
        session.isSidebarVisible = sidebarVisible
        let present = {
            window.orderFront(nil)
            if becomingKey {
                controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            }
        }
        switch presentation {
        case .immediately:
            present()
        case .nextTurn:
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    present()
                    continuation.resume()
                }
            }
        }
        return LaunchWindowFixture(controller: controller, window: window)
    }

    private static func findView(in view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        if matches(view) { return view }
        for subview in view.subviews {
            if let found = findView(in: subview, where: matches) { return found }
        }
        return nil
    }

    private static func findSplitView(_ view: NSView) -> NSSplitView? {
        findView(in: view) { ($0 as? NSSplitView)?.delegate is LeoSplitViewController } as? NSSplitView
    }

    private static func findSearchField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.delegate is LeoSidebarSearchField.Coordinator { return field }
        return view.subviews.lazy.compactMap(findSearchField).first
    }

    enum FixtureError: Error {
        case noLeoWindow
        case noSearchField
    }
}
