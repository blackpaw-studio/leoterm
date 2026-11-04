import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// The toolbar's real height, read from the window, replaces the fixed
/// titlebar inset (so full screen, which releases the toolbar, releases it
/// too).
@MainActor
struct LeoToolbarInsetTests {
    @Test func theInsetIsTheGapBetweenTheWindowTopAndTheContentLayoutRect() {
        #expect(LeoToolbarInset.height(contentHeight: 600, contentLayoutMaxY: 548) == 52)
    }

    @Test func fullScreenAtRestHasNoInset() {
        #expect(LeoToolbarInset.height(contentHeight: 900, contentLayoutMaxY: 900) == 0)
    }

    @Test func aNegativeGapClampsToZero() {
        #expect(LeoToolbarInset.height(contentHeight: 600, contentLayoutMaxY: 640) == 0)
    }

    @Test func theHeaderLineIsTheChromeInsetBelowTheToolbar() {
        let inset = LeoToolbarInset(height: 52)
        #expect(inset.headerTop == 52 + LeoSidebarChromeMetrics.topInset)
    }

    /// The window's own state: a titled window with a toolbar leaves a gap
    /// above its content layout rect; the same window in native full screen
    /// has its toolbar auto-hidden, and the content reaches the top.
    private static func makeWindow(fullScreen: Bool) -> NSWindow {
        let window = (fullScreen ? FullScreenWindow.self : NSWindow.self).init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "leo.test.toolbar.\(UUID().uuidString)")
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        return window
    }

    /// A window reporting native full screen: setting the real style bit on
    /// an off-screen window would try to run the full-screen transition.
    private final class FullScreenWindow: NSWindow {
        override var styleMask: NSWindow.StyleMask {
            get { super.styleMask.union(.fullScreen) }
            set { super.styleMask = newValue }
        }
    }

    @Test func aWindowedToolbarReservesItsHeight() {
        let inset = LeoToolbarInset()
        inset.update(from: Self.makeWindow(fullScreen: false))
        #expect(inset.height > 0)
    }

    @Test func nativeFullScreenWithTheToolbarAutoHiddenHasNoInset() {
        let inset = LeoToolbarInset(height: 52)
        inset.update(from: Self.makeWindow(fullScreen: true))
        #expect(inset.height == 0)
    }
}
