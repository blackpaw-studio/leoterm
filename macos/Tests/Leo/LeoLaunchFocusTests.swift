import AppKit
import Testing

@testable import Ghostty

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
/// from `GhosttyAttachContentHostFocusTests`.
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

        #expect(
            fixture.window.firstResponder === fixture.window,
            "first responder on launch: \(fixture.describeFirstResponder())"
        )
        #expect(!fixture.searchFieldHasFocus, "the search field took focus on launch")
        #expect(!fixture.window.isKeyWindow, "the test's window took key status")
    }

    /// Keyboard-first: leaving the first pick to the content area must not
    /// cost the key view loop AppKit builds with that pick, so Tab from the
    /// start screen still reaches the search field, and Tab out of the
    /// field still reaches the agent list.
    @Test func tabFromTheStartScreenStillReachesTheSearchFieldThenTheList() async throws {
        let fixture = try await LaunchWindowFixture.make()
        defer { fixture.close() }

        fixture.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: fixture.window))
        await nextMainTurn()

        #expect(fixture.searchField.nextValidKeyView is NSTableView, "after the field: \(String(describing: fixture.searchField.nextValidKeyView))")
        fixture.window.selectNextKeyView(nil)
        #expect(fixture.searchFieldHasFocus, "Tab from the start screen: \(fixture.describeFirstResponder())")
        #expect(!fixture.window.isKeyWindow, "the test's window took key status")
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
}

/// A launch window: a start-screen `TerminalController` with its sidebar
/// showing, ordered on screen (never key) with the sidebar's search field
/// built.
@MainActor
private struct LaunchWindowFixture {
    let controller: TerminalController
    let window: NSWindow
    let searchField: NSTextField

    /// True while the search field is being edited (its field editor is
    /// the window's first responder).
    var searchFieldHasFocus: Bool {
        guard let editor = searchField.currentEditor() else { return window.firstResponder === searchField }
        return window.firstResponder === editor
    }

    func describeFirstResponder() -> String {
        guard let responder = window.firstResponder else { return "nil" }
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            return "a field editor for \(String(describing: editor.delegate))"
        }
        return "\(type(of: responder))"
    }

    func close() {
        controller.closeTabImmediately(registerRedo: false)
    }

    static func make() async throws -> LaunchWindowFixture {
        try #require((NSApp.delegate as? AppDelegate)?.leoRuntime != nil, "the test host has no LeoRuntime")
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty, "the test host has no Ghostty.App")
        try #require(ghostty.readiness == .ready, "the test host's Ghostty.App isn't ready")
        let controller = TerminalController(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        guard let window = controller.window, let session = controller.leoSession else {
            controller.closeTabImmediately(registerRedo: false)
            throw FixtureError.noLeoWindow
        }
        session.isSidebarVisible = true
        window.orderFront(nil)
        guard let field = await searchField(in: window) else {
            controller.closeTabImmediately(registerRedo: false)
            throw FixtureError.noSearchField
        }
        return LaunchWindowFixture(controller: controller, window: window, searchField: field)
    }

    /// The sidebar's search field, once the split view has built it.
    private static func searchField(in window: NSWindow) async -> NSTextField? {
        for _ in 0 ..< 50 {
            if let field = window.contentView.flatMap(findSearchField) { return field }
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
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
