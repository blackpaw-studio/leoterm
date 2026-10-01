import AppKit
import Testing

@testable import Ghostty

/// B-086: the first agent attached into a start screen after launch shrank
/// the window. With `window-width`/`window-height` configured, a window's
/// first content applied the SwiftUI intrinsic size before it had caught
/// up with the new surface. A window already on screen keeps its frame
/// when its content first fills (P1, P2); only a window not yet shown is
/// sized, from the configured size plus the sidebar.
///
/// `initialSize` is set on the filled surface by hand, as Ghostty's
/// `window-width`/`window-height` set it on a new surface, and the size
/// step that `fillPlaceholder` runs for a window's first content is then
/// run again. The windows are real and shown, and they run the default
/// shell, never an agent. Needs the app's real `Ghostty.App`.
@MainActor @Suite(.serialized) struct LeoFirstAttachWindowSizeTests {
    /// What `window-width`/`window-height` give a surface, in points.
    private static let configuredSize = NSSize(width: 640, height: 384)

    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }
    private static var hasGhostty: Bool { app?.ghostty.app != nil }

    @MainActor private struct Fixture {
        let app: AppDelegate
        let controller: TerminalController
        let window: NSWindow
        let host: GhosttyAttachContentHost
        let origin: LeoWindowID
        let savedPosition: Any?

        /// A start screen as the launch opens one, before it is presented.
        static func make() throws -> Fixture {
            let app = try #require(LeoFirstAttachWindowSizeTests.app)
            let savedPosition = UserDefaults.ghostty.object(forKey: LastWindowPosition.positionKey)
            let controller = withoutUndo(app) { TerminalController.leoNewPlaceholderWindow(app.ghostty) }
            let window = try #require(controller.window)
            let registry = LeoWindowSessionRegistry()
            let origin = registry.makeSession(window: window, controller: controller, defaults: LeoInMemoryDefaults()).id
            let host = GhosttyAttachContentHost(registry: registry, requestConfigStore: LeoRequestConfigStore()) {
                .init(isActive: false, keyWindow: nil)
            }
            return Fixture(app: app, controller: controller, window: window, host: host, origin: origin, savedPosition: savedPosition)
        }

        /// Shows the start screen, then gives it a known frame on screen.
        static func shown() async throws -> Fixture {
            let fixture = try make()
            await drainMainQueue(turns: 4)
            try #require(fixture.window.isVisible, "the start screen never showed")
            let screen = try #require(fixture.window.screen ?? NSScreen.main)
            fixture.window.setFrame(knownFrame(on: screen.visibleFrame), display: true)
            await drainMainQueue(turns: 2)
            return fixture
        }

        /// What `showInContent` does for a window showing its start screen.
        func fill() throws -> (handle: AttachmentHandle, surface: Ghostty.SurfaceView) {
            let handle = try withoutUndo(app) {
                try host.fillPlaceholder(command: "", workingDirectory: nil, origin: origin, surfaceID: nil, requestID: UUID())
            }
            return (handle, try #require(controller.surfaceTree.first { $0.id == handle.surfaceID }))
        }

        /// The shown terminal's shell closes: the start screen comes back.
        func closeShownTerminal(_ handle: AttachmentHandle) throws {
            host.closeTerminal(handle)
            try #require(controller.surfaceTree.isEmpty, "the start screen never came back")
        }

        /// The first content's size step, now that the surface has its
        /// configured size -- what `fillPlaceholder` runs for it.
        func applyFirstContentSize(
            to surface: Ghostty.SurfaceView, configuredSize: NSSize = LeoFirstAttachWindowSizeTests.configuredSize
        ) {
            surface.initialSize = configuredSize
            controller.leoApplyInitialSize()
        }

        /// The sidebar's width in the window's split, nil while collapsed.
        var sidebarWidth: CGFloat? {
            guard let contentView = window.contentView,
                  let split = Self.splitController(in: contentView),
                  let item = split.sidebarItem, !item.isCollapsed else { return nil }
            return item.viewController.view.frame.width
        }

        private static func splitController(in view: NSView) -> LeoSplitViewController? {
            if let split = (view as? NSSplitView)?.delegate as? LeoSplitViewController { return split }
            return view.subviews.lazy.compactMap { splitController(in: $0) }.first
        }

        var contentSize: NSSize { window.contentRect(forFrameRect: window.frame).size }

        func close() {
            window.close()
            if let savedPosition {
                UserDefaults.ghostty.set(savedPosition, forKey: LastWindowPosition.positionKey)
            } else {
                UserDefaults.ghostty.removeObject(forKey: LastWindowPosition.positionKey)
            }
        }

        /// 1000x700 when it fits, inset from the screen's corner.
        private static func knownFrame(on visible: NSRect) -> NSRect {
            let inset: CGFloat = 40
            let width = min(1000, visible.width - 2 * inset)
            let height = min(700, visible.height - 2 * inset)
            return NSRect(x: visible.minX + inset, y: visible.maxY - inset - height, width: width, height: height)
        }
    }

    private static func withoutUndo<T>(_ app: AppDelegate, _ body: () throws -> T) rethrows -> T {
        app.undoManager.disableUndoRegistration()
        defer { app.undoManager.enableUndoRegistration() }
        return try body()
    }

    /// Enough main-queue turns for any deferred resize to land.
    private static func drainMainQueue(turns: Int = 12) async {
        for _ in 0..<turns {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    @Test(.enabled("needs the app's Ghostty.App") { await MainActor.run { Self.hasGhostty } })
    func firstAttachKeepsTheShownWindowsFrame() async throws {
        let fixture = try await Fixture.shown()
        defer { fixture.close() }
        let frame = fixture.window.frame

        let surface = try fixture.fill().surface
        fixture.applyFirstContentSize(to: surface)
        await Self.drainMainQueue()

        #expect(fixture.window.frame == frame, "the window resized on its own")
    }

    /// B-057: a start screen its last terminal left keeps the window's size
    /// when it fills again.
    @Test(.enabled("needs the app's Ghostty.App") { await MainActor.run { Self.hasGhostty } })
    func firstFillAfterAStartScreenLeaveKeepsTheFrame() async throws {
        let fixture = try await Fixture.shown()
        defer { fixture.close() }
        let frame = fixture.window.frame
        try fixture.closeShownTerminal(fixture.fill().handle)

        let surface = try fixture.fill().surface
        surface.initialSize = Self.configuredSize
        await Self.drainMainQueue()

        #expect(fixture.window.frame == frame, "the window resized on its own")
    }

    /// A window filled before it is presented (File > New Terminal with no
    /// window open, when its shell lands first) takes the configured size
    /// -- the terminal's, plus the sidebar beside it -- never the SwiftUI
    /// view's, and keeps it once presented.
    @Test(.enabled("needs the app's Ghostty.App") { await MainActor.run { Self.hasGhostty } })
    func aWindowFilledBeforeItShowsTakesTheConfiguredSize() async throws {
        let fixture = try Fixture.make()
        defer { fixture.close() }
        try #require(!fixture.window.isVisible)
        let session = try #require(fixture.controller.leoSession)
        let sidebar = session.isSidebarVisible ? session.displayedWidth + LeoSidebarSplitMetrics.dividerWidth : 0
        let expected = NSSize(width: Self.configuredSize.width + sidebar, height: Self.configuredSize.height)

        let surface = try fixture.fill().surface
        fixture.applyFirstContentSize(to: surface)
        #expect(fixture.contentSize == expected)

        await Self.drainMainQueue()
        #expect(fixture.window.isVisible, "the window was still presented")
        #expect(fixture.contentSize == expected, "presenting it kept the size")
    }

    /// B-091: a configured terminal narrower than the content minimum
    /// opens beside the sidebar at that minimum, so the sidebar keeps its
    /// stored width rather than being clamped to make room (D-145).
    @Test(.enabled("needs the app's Ghostty.App") { await MainActor.run { Self.hasGhostty } })
    func aNarrowConfiguredTerminalOpensWideEnoughForTheStoredSidebar() async throws {
        let fixture = try Fixture.make()
        defer { fixture.close() }
        let session = try #require(fixture.controller.leoSession)
        try #require(session.isSidebarVisible)
        let narrow = NSSize(width: 300, height: Self.configuredSize.height)

        let surface = try fixture.fill().surface
        fixture.applyFirstContentSize(to: surface, configuredSize: narrow)
        await Self.drainMainQueue()

        let expectedWidth = LeoSidebarSplitMetrics.contentMinimumWidth + session.displayedWidth + LeoSidebarSplitMetrics.dividerWidth
        #expect(fixture.contentSize.width == expectedWidth)
        let sidebarWidth = try #require(fixture.sidebarWidth, "the sidebar showed")
        #expect(abs(sidebarWidth - session.displayedWidth) <= 1, "sidebar \(sidebarWidth), stored \(session.displayedWidth)")
    }

    /// B-097: Window > Reset Window Size on a start screen that has filled
    /// returns to the configured size -- the terminal's, plus the sidebar
    /// beside it -- never the SwiftUI view's intrinsic size.
    @Test(.enabled("needs the app's Ghostty.App") { await MainActor.run { Self.hasGhostty } })
    func resetWindowSizeOnAFilledStartScreenTakesTheConfiguredSize() async throws {
        let fixture = try await Fixture.shown()
        defer { fixture.close() }
        let session = try #require(fixture.controller.leoSession)
        let sidebar = session.isSidebarVisible ? session.displayedWidth + LeoSidebarSplitMetrics.dividerWidth : 0
        let expected = NSSize(width: Self.configuredSize.width + sidebar, height: Self.configuredSize.height)

        let surface = try fixture.fill().surface
        fixture.applyFirstContentSize(to: surface)
        await Self.drainMainQueue()
        fixture.controller.returnToDefaultSize(nil)
        await Self.drainMainQueue()

        #expect(fixture.contentSize == expected, "Reset Window Size used the SwiftUI view's size")
    }
}
