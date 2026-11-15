import AppKit
import Testing

@testable import Ghostty

/// B-143: the agent toolbar does not keep a closed window alive. Its
/// tracking separator holds the window's split view, and in the app the
/// split's panes hold the window (their SwiftUI graph holds its controller).
/// The controller breaks its content's hold as the window closes
/// (`BaseTerminalController.windowWillClose` empties the window), so a
/// separator still holding the split would keep the closed window, its
/// controller and its window-server window for good.
///
/// Runs inside `LeoIdleEventLoop`, so only the wakes of the window it
/// closes drain what held it, and keeps only a weak reference to it.
@MainActor @Suite(.serialized)
struct LeoAgentToolbarCloseTests {
    /// A pane holding the window, as the app's panes do through its controller.
    private final class WindowHoldingPane: NSView {
        var heldWindow: NSWindow?
    }

    /// The window owns its toolbar's delegate, as `LeoAgentTerminalWindow` does.
    private final class ToolbarWindow: NSWindow {
        let leoToolbar = LeoAgentToolbar()
    }

    private static let wakeInterval: TimeInterval = 0.05
    private static let wakeLimit: TimeInterval = 5
    private static let freeTimeout: Duration = .seconds(3)

    /// Inside the loop: a shown window with the toolbar, its separator
    /// tracking a split whose pane holds the window.
    private static func makeWindow() -> ToolbarWindow {
        let window = ToolbarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        split.isVertical = true
        let pane = WindowHoldingPane()
        pane.heldWindow = window
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(pane)
        window.contentView = split
        window.leoToolbar.install(on: window)
        window.leoToolbar.attach(splitView: split)
        window.orderFrontRegardless()
        return window
    }

    @Test func aClosedWindowIsFreedThoughItsSeparatorTrackedItsSplit() async throws {
        let (number, hadSeparator, isFreed) = await LeoIdleEventLoop.run { loop -> (Int, Bool, Bool) in
            weak var traced: NSWindow?
            let (number, hadSeparator) = autoreleasepool { () -> (Int, Bool) in
                let window = Self.makeWindow()
                traced = window
                let items = window.toolbar?.items ?? []
                return (window.windowNumber, items.contains { $0.itemIdentifier == .leoSplitSeparator })
            }
            loop.turn {
                guard let window = traced else { return }
                window.close()
                // As the window's controller does as it closes.
                window.contentView = nil
                LeoEventLoop.wakeUntilFreed(window, number: number, every: Self.wakeInterval, for: Self.wakeLimit)
            }
            let isFreed = loop.idle(
                until: { traced == nil && !LeoEventLoop.windowServerLists(number) },
                wakingFor: number, timeout: Self.freeTimeout
            )
            return (number, hadSeparator, isFreed)
        }

        try #require(hadSeparator, "the toolbar never put up its tracking separator")
        #expect(isFreed, "the closed window #\(number) is still alive")
    }

    /// A split handed over only after its window closed (SwiftUI's first
    /// layout coming late) doesn't put the hold back.
    @Test func aSplitHandedOverAfterTheWindowClosedGetsNoSeparator() {
        let window = ToolbarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.leoToolbar.install(on: window)
        window.close()

        window.leoToolbar.attach(splitView: NSSplitView())

        let identifiers = window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(!identifiers.contains(.leoSplitSeparator), "\(identifiers)")
    }
}
