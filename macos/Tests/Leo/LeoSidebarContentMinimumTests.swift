import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-091: a wide sidebar never squeezes the content beside it under
/// `LeoSidebarSplitMetrics.contentMinimumWidth`, the width the start
/// screen's buttons need. The sidebar's maximum follows the window: it
/// gives way (down to its own minimum) before the content does.
@MainActor struct LeoSidebarContentMinimumTests {
    private static let contentMinimum = LeoSidebarSplitMetrics.contentMinimumWidth
    /// The B-084 report: a 420 pt sidebar in an 800 pt window.
    private static let reportedWindowWidth: CGFloat = 800
    private static let wideWindowWidth: CGFloat = 1_200
    private static let height: CGFloat = 600

    // MARK: The maximum

    @Test func theSidebarsMaximumLeavesTheContentItsMinimum() {
        let maximum = LeoSidebarSplitMetrics.sidebarMaximumWidth(splitWidth: Self.reportedWindowWidth, dividerThickness: 1)

        #expect(maximum == Self.reportedWindowWidth - 1 - Self.contentMinimum)
    }

    @Test(arguments: [(2_000, LeoSidebarSplitMetrics.maximumWidth), (400, LeoSidebarSplitMetrics.minimumWidth)] as [(CGFloat, CGFloat)])
    func theSidebarsMaximumStaysWithinItsOwnBounds(splitWidth: CGFloat, expected: CGFloat) {
        #expect(LeoSidebarSplitMetrics.sidebarMaximumWidth(splitWidth: splitWidth, dividerThickness: 1) == expected)
    }

    /// Ground truth for the constant: the start screen's own view, at its
    /// ideal width (every button title whole), with the HIG's 20 pt window
    /// margins either side.
    @Test func theStartScreensButtonsFitTheContentMinimum() {
        let placeholder = LeoPlaceholderView(
            model: LeoSidebarModel(), hostSelection: .isolatedForTesting(), shortcutHints: LeoShortcutHints(),
            openPicker: {}, newTerminal: {}, toggleDrawer: {})
        let idealWidth = NSHostingView(rootView: placeholder).fittingSize.width

        #expect(idealWidth > 300, "measured the three buttons, not an empty view: \(idealWidth)")
        #expect(idealWidth + 2 * Self.windowMargin <= Self.contentMinimum, "ideal \(idealWidth)")
    }

    private static let windowMargin: CGFloat = 20

    // MARK: In a window

    @Test func aWideStoredSidebarLeavesTheContentItsMinimum() async {
        let defaults = LeoInMemoryDefaults()
        defaults.set(Double(LeoSidebarSplitMetrics.maximumWidth), forKey: LeoWindowSession.sidebarWidthKey)
        let harness = await Harness(defaults: defaults, windowWidth: Self.reportedWindowWidth)
        defer { harness.close() }

        #expect(abs(harness.contentWidth - Self.contentMinimum) <= 1, "content \(harness.contentWidth)")
        #expect(abs(harness.sidebarWidth - (Self.reportedWindowWidth - 1 - Self.contentMinimum)) <= 1)
        let clamped = harness.sidebarWidth

        // A clamp, not the user's width: widening keeps it, and the next
        // launch still opens at the stored width (D-231).
        await harness.resize(to: Self.wideWindowWidth, isLive: false)
        #expect(abs(harness.sidebarWidth - clamped) <= 1)
        #expect(defaults.double(forKey: LeoWindowSession.sidebarWidthKey) == Double(LeoSidebarSplitMetrics.maximumWidth))
    }

    @Test func draggingTheSidebarWideStopsAtTheContentMinimum() async {
        let defaults = LeoInMemoryDefaults()
        let harness = await Harness(defaults: defaults, windowWidth: Self.reportedWindowWidth)
        defer { harness.close() }

        harness.dragDivider(to: LeoSidebarSplitMetrics.maximumWidth)
        await harness.settle()

        #expect(abs(harness.contentWidth - Self.contentMinimum) <= 1, "content \(harness.contentWidth)")
        #expect(abs(defaults.double(forKey: LeoWindowSession.sidebarWidthKey) - Double(harness.sidebarWidth)) <= 1)
    }

    /// Narrowing: the content absorbs until its minimum, then the sidebar
    /// gives way. Widening back gives the sidebar its width back, as with
    /// the terminal's minimum (B-089), and stores nothing (D-233).
    @Test(arguments: [true, false])
    func narrowingTheWindowNarrowsAWideSidebarBeforeTheContent(isLive: Bool) async {
        let defaults = LeoInMemoryDefaults()
        defaults.set(Double(LeoSidebarSplitMetrics.maximumWidth), forKey: LeoWindowSession.sidebarWidthKey)
        let harness = await Harness(defaults: defaults, windowWidth: Self.wideWindowWidth)
        defer { harness.close() }
        #expect(abs(harness.sidebarWidth - LeoSidebarSplitMetrics.maximumWidth) <= 1)

        await harness.resize(to: Self.reportedWindowWidth, isLive: isLive)
        #expect(abs(harness.contentWidth - Self.contentMinimum) <= 1, "content \(harness.contentWidth)")

        await harness.resize(to: Self.wideWindowWidth, isLive: isLive)
        #expect(abs(harness.sidebarWidth - LeoSidebarSplitMetrics.maximumWidth) <= 1)
        #expect(defaults.double(forKey: LeoWindowSession.sidebarWidthKey) == Double(LeoSidebarSplitMetrics.maximumWidth))
    }

    /// Too narrow for both: the sidebar holds its own minimum.
    @Test func aWindowTooNarrowForBothKeepsTheSidebarsMinimum() async {
        let defaults = LeoInMemoryDefaults()
        defaults.set(Double(LeoSidebarSplitMetrics.maximumWidth), forKey: LeoWindowSession.sidebarWidthKey)
        let harness = await Harness(defaults: defaults, windowWidth: Self.wideWindowWidth)
        defer { harness.close() }

        await harness.resize(to: 500, isLive: true)

        #expect(abs(harness.sidebarWidth - LeoSidebarSplitMetrics.minimumWidth) <= 1)
        #expect(harness.sidebarItem?.isCollapsed == false)
    }

    /// The split the app builds, in a real window, persisting through a
    /// window session as the app does.
    @MainActor private final class Harness {
        let components: (controller: LeoSplitViewController,
                         sidebarHosting: NSHostingController<AnyView>,
                         detailHosting: NSHostingController<AnyView>)
        let window: NSWindow

        init(defaults: UserDefaults, windowWidth: CGFloat) async {
            let session = LeoWindowSession(defaults: defaults)
            components = LeoSplitViewControllerFactory.make(
                isSidebarVisible: true,
                preferredWidth: session.preferredWidth,
                onDividerWidthChange: { session.setPreferredWidth($0) },
                sidebar: Self.flexibleView(),
                detail: Self.flexibleView())
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: LeoSidebarContentMinimumTests.height),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = components.controller
            window.setContentSize(NSSize(width: windowWidth, height: LeoSidebarContentMinimumTests.height))
            window.makeKeyAndOrderFront(nil)
            layout()
            for _ in 0..<3 { await settle() }
        }

        var sidebarItem: NSSplitViewItem? { components.controller.sidebarItem }
        var sidebarWidth: CGFloat { components.sidebarHosting.view.frame.width }
        var contentWidth: CGFloat { components.detailHosting.view.frame.width }

        func close() { window.close() }

        func settle() async {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            layout()
        }

        func dragDivider(to width: CGFloat) {
            components.controller.splitView.setPosition(width, ofDividerAt: 0)
            layout()
        }

        /// Live: 10 pt at a time, settling after each; otherwise one jump.
        func resize(to width: CGFloat, isLive: Bool) async {
            var current = window.contentLayoutRect.width
            let step: CGFloat = isLive ? 10 : .greatestFiniteMagnitude
            while abs(width - current) > 0.5 {
                current += max(-step, min(step, width - current))
                window.setContentSize(NSSize(width: current, height: LeoSidebarContentMinimumTests.height))
                layout()
                await settle()
            }
            for _ in 0..<3 { await settle() }
        }

        private func layout() {
            window.layoutIfNeeded()
            components.controller.view.layoutSubtreeIfNeeded()
        }

        private static func flexibleView() -> AnyView {
            AnyView(Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity))
        }
    }
}
