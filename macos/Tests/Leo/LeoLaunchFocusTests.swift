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

        let field = try #require(fixture.searchField, "the search field wasn't built when the key view loop was rebuilt")
        #expect(field.nextValidKeyView is NSTableView, "after the field: \(String(describing: field.nextValidKeyView))")
        fixture.window.selectNextKeyView(nil)
        #expect(fixture.hasFocus(field), "Tab from the start screen: \(fixture.describeFirstResponder())")
        #expect(!fixture.window.isKeyWindow, "the test's window took key status")
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

    /// The sidebar's search field, once the split view has built it.
    func waitForSearchField() async throws -> NSTextField {
        for _ in 0 ..< 50 {
            if let field = searchField { return field }
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.noSearchField
    }

    func close() {
        controller.closeTabImmediately(registerRedo: false)
    }

    /// `becomingKey` delivers what `makeKeyAndOrderFront` does as it
    /// returns -- the window's did-become-key, in the same turn as the
    /// order-in -- without taking key status from the other suites.
    static func make(_ presentation: LeoLaunchFocusTests.Presentation = .nextTurn, becomingKey: Bool = false) async throws -> LaunchWindowFixture {
        try #require((NSApp.delegate as? AppDelegate)?.leoRuntime != nil, "the test host has no LeoRuntime")
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty, "the test host has no Ghostty.App")
        try #require(ghostty.readiness == .ready, "the test host's Ghostty.App isn't ready")
        let controller = TerminalController(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
        guard let window = controller.window, let session = controller.leoSession else {
            controller.closeTabImmediately(registerRedo: false)
            throw FixtureError.noLeoWindow
        }
        session.isSidebarVisible = true
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

    private static func findSearchField(_ view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.delegate is LeoSidebarSearchField.Coordinator { return field }
        return view.subviews.lazy.compactMap(findSearchField).first
    }

    enum FixtureError: Error {
        case noLeoWindow
        case noSearchField
    }
}
