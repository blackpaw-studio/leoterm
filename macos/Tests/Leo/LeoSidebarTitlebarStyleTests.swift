import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-074, reworked for the agent toolbar: every Leo agent window is a
/// `LeoAgentTerminalWindow` with a unified toolbar whatever
/// `macos-titlebar-style` says. Each test builds a window the way the app
/// does: a `Ghostty.App` loaded from a config file that sets the style (and
/// nothing else), and a real `TerminalController` on it, which picks the
/// window's nib itself. The real `LeoSidebarSplit` lays out inside; the
/// header's frame and the window buttons' frames are then compared in
/// window coordinates. The windows are shown, never made key, so AppKit
/// places the toolbar and buttons.
///
/// Needs the test host's `LeoRuntime` and a loadable Ghostty config; either
/// missing fails the test rather than passing it silently.
@MainActor @Suite(.serialized)
struct LeoSidebarTitlebarStyleTests {
    /// How far a header row may sit from where the chrome metrics put it:
    /// the row's height is the button's, so the title is centred in it.
    private static let rowTolerance: CGFloat = 6

    @Test(arguments: TitlebarStyle.allCases)
    func everyStyleOpensALeoAgentWindow(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }

        #expect(fixture.window is LeoAgentTerminalWindow, "\(style): \(type(of: fixture.window))")
        #expect(fixture.window.toolbar != nil, "\(style): no toolbar")
    }

    @Test(arguments: TitlebarStyle.allCases)
    func theToolbarHoldsTheAgentItemsWithTheCapsuleCentred(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }
        let toolbar = try #require(fixture.window.toolbar, "\(style): no toolbar")

        #expect(
            toolbar.items.map(\.itemIdentifier) == LeoAgentToolbar.itemOrder,
            "\(style): \(toolbar.items.map(\.itemIdentifier.rawValue))")
        // The trailing groups (toggles, labelled switch, Interrupt, "⋯") need a wide window to leave the capsule centred.
        fixture.window.setContentSize(NSSize(width: 1500, height: fixture.window.contentLayoutRect.height))
        for _ in 0 ..< 100 where toolbar.centeredItemIdentifiers != [.leoActivity] {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(toolbar.centeredItemIdentifiers == [.leoActivity], "\(style)")
        #expect(toolbar.allowsUserCustomization, "\(style)")
        #expect(fixture.window.toolbarStyle == .unified, "\(style)")
    }

    /// B-349: the update pill used to hang in a titlebar accessory under the
    /// unified toolbar, off its row; it is a toolbar item now, and neither
    /// the accessory nor the corner overlay shows a second copy.
    @Test(arguments: TitlebarStyle.allCases)
    func theUpdatePillIsAToolbarItemNotATitlebarAccessory(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }
        let window = try #require(fixture.window as? TerminalWindow)

        let accessories = window.titlebarAccessoryViewControllers.filter {
            $0.view is NonDraggableHostingView<TerminalWindow.UpdateAccessoryView>
        }
        #expect(accessories.isEmpty, "\(style): the update pill is still a titlebar accessory")
        #expect(!fixture.controller.updateOverlayIsVisible, "\(style): the update pill also shows as a corner overlay")
        let identifiers = fixture.window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(identifiers.contains(.leoUpdate), "\(style): \(identifiers.map(\.rawValue))")
    }

    /// B-358: the reset-zoom button was a `.right` titlebar accessory, which
    /// hangs under the unified toolbar off its row (as the update pill did,
    /// B-349). It is a toolbar item that shows while a split is zoomed.
    @Test(arguments: TitlebarStyle.allCases)
    func resetZoomIsAToolbarItemNotATitlebarAccessory(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }
        let window = try #require(fixture.window as? TerminalWindow)

        let accessories = window.titlebarAccessoryViewControllers.filter {
            $0.view is NSHostingView<TerminalWindow.ResetZoomAccessoryView>
        }
        #expect(accessories.isEmpty, "\(style): reset zoom is still a titlebar accessory")
        let identifiers = fixture.window.toolbar?.items.map(\.itemIdentifier) ?? []
        #expect(identifiers.contains(.leoResetZoom), "\(style): \(identifiers.map(\.rawValue))")
    }

    @Test(arguments: TitlebarStyle.allCases)
    func allThreeWindowButtonsAreVisible(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }

        #expect(fixture.visibleWindowButtons.count == 3, "\(style): \(fixture.visibleWindowButtons)")
    }

    @Test(arguments: TitlebarStyle.allCases)
    func theWindowButtonsNeverOverlapTheSidebarHeader(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }

        for (kind, button) in fixture.visibleWindowButtons {
            #expect(!button.intersects(fixture.header), "\(style): the \(kind) button \(button) overlaps the header; \(fixture.diagnostics)")
        }
    }

    /// The glass sidebar runs to the window's top edge, under the traffic
    /// lights; the toolbar's real inset is what the header takes.
    @Test(arguments: TitlebarStyle.allCases)
    func theSplitRunsToTheWindowTop(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }

        #expect(fixture.splitTop == fixture.windowTop, "\(style): \(fixture.diagnostics)")
    }

    /// The header's inset under the toolbar's bottom edge
    /// (`contentLayoutRect`), whatever height the toolbar has.
    /// `.hostOnly`: hosted macos-26 places the header differently, AppKit layout rather than ours.
    @Test(.hostOnly, arguments: TitlebarStyle.allCases)
    func theHeaderSitsTheChromeInsetBelowTheToolbar(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }

        let gap = fixture.titlebarBottom - fixture.header.maxY
        #expect(gap >= LeoSidebarChromeMetrics.topInset - 1, "\(style): the header sits \(gap) pt under the toolbar; \(fixture.diagnostics)")
        #expect(
            gap <= LeoSidebarChromeMetrics.topInset + Self.rowTolerance,
            "\(style): the header sits \(gap) pt under the toolbar; \(fixture.diagnostics)"
        )
    }

    /// With decorations off there's no titlebar and so no toolbar.
    @Test func aWindowWithoutDecorationsHasNoToolbar() async throws {
        let fixture = try await StyledWindowFixture.make(.native, decorations: false)
        defer { fixture.close() }

        #expect(!(fixture.window is LeoAgentTerminalWindow), "\(type(of: fixture.window))")
        #expect(fixture.window.toolbar == nil)
    }

    /// Only an agent window's split extends into the toolbar's region.
    @Test func onlyAnAgentWindowSplitIgnoresTheTopEdge() async throws {
        let fixture = try await StyledWindowFixture.make(.native)
        defer { fixture.close() }

        #expect(LeoTitlebarInsets.splitIgnoredEdges(in: fixture.window) == .top)
        let plainWindow = NSWindow()
        plainWindow.isReleasedWhenClosed = false
        #expect(LeoTitlebarInsets.splitIgnoredEdges(in: plainWindow) == [])
        #expect(LeoTitlebarInsets.splitIgnoredEdges(in: nil) == [])
    }

    /// The split applies the sidebar's stored width after the first layout,
    /// and the representable reassigns the sidebar's root view on every
    /// SwiftUI update, which drops the probe. A probe that reported at the
    /// old width then holds a stale host forever: `settledHeader` has to
    /// notice and re-probe, not time out (CI, B-154's batch).
    @Test func theProbeSurvivesTheSidebarResizingAfterItReported() async throws {
        let fixture = try await StyledWindowFixture.make(.native)
        defer { fixture.close() }
        let sidebar = try #require(fixture.split.sidebarItem?.viewController as? NSHostingController<AnyView>)
        let unprobed = sidebar.rootView
        let frames = HeaderProbe()
        try #require(await frames.settledHeader(probing: sidebar) != nil, "the probe never reported")

        // Shrink to the minimum when there is room (always under the
        // window's cap, whatever width the shared defaults stored); else grow.
        let before = sidebar.view.bounds.width
        let minimum = LeoSidebarSplitMetrics.minimumWidth
        sidebar.rootView = unprobed
        fixture.split.applyProgrammaticWidth(before > minimum + 40 ? minimum : before + 40)
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        try #require(sidebar.view.bounds.width != before, "the sidebar stayed \(before) pt wide; the resize never happened")

        let settled = try #require(
            await frames.settledHeader(probing: sidebar),
            "\(frames); sidebar \(sidebar.view.bounds) (was \(before) wide)")
        #expect(settled.maxX <= sidebar.view.bounds.width, "\(settled) in \(sidebar.view.bounds)")
    }
}

/// A `macos-titlebar-style` value. Leo windows ignore it (they always take
/// the agent toolbar window), which the tests above pin for every value.
enum TitlebarStyle: String, CaseIterable, CustomTestStringConvertible {
    case native
    case transparent
    case tabs
    case hidden

    var testDescription: String { rawValue }

    /// The config value that selects this style.
    var configValue: String { rawValue }
}

/// The app's own `TerminalController` on an empty placeholder tree, so
/// the window comes up the way the app's does, with no surface to fill.
private final class StyledTerminalController: TerminalController {
    init(_ ghostty: Ghostty.App) {
        super.init(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The nibs live in the app, not in the test bundle this subclass
    /// comes from.
    override var windowNibPath: String? {
        windowNibName.flatMap { Bundle(for: TerminalController.self).path(forResource: $0, ofType: "nib") }
    }
}

/// A shown, laid-out window of one titlebar style, with the sidebar
/// header's frame and the window buttons' frames in window coordinates.
/// Shared with `LeoSidePaneTitlebarStyleTests` (B-100).
@MainActor
struct StyledWindowFixture {
    let controller: TerminalController
    let window: NSWindow
    /// The window's sidebar split.
    let split: LeoSplitViewController
    /// The header row (title and accessory), in window coordinates.
    let header: CGRect
    /// The header's accessory (the + button), in window coordinates (B-153).
    let accessory: CGRect
    /// The split view's top edge (sidebar and terminal), in window
    /// coordinates.
    let splitTop: CGFloat
    let diagnostics: String

    /// The window's top edge, in window coordinates.
    var windowTop: CGFloat { window.frame.height }

    /// The titlebar's bottom edge (the top of the content layout rect), in
    /// window coordinates.
    var titlebarBottom: CGFloat { window.contentLayoutRect.maxY }

    /// The standard window buttons AppKit draws, in window coordinates.
    var visibleWindowButtons: [(NSWindow.ButtonType, CGRect)] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind in
            guard let button = window.standardWindowButton(kind), !button.isHiddenOrHasHiddenAncestor,
                  button.alphaValue > 0 else { return nil }
            return (kind, button.convert(button.bounds, to: nil))
        }
    }

    func close() {
        controller.closeTabImmediately(registerRedo: false)
    }

    static func make(_ style: TitlebarStyle, decorations: Bool = true) async throws -> StyledWindowFixture {
        try #require((NSApp.delegate as? AppDelegate)?.leoRuntime != nil, "the test host has no LeoRuntime")
        let ghostty = try StyleConfig.app(for: style, decorations: decorations)
        try #require(ghostty.readiness == .ready, "\(style): the Ghostty app didn't load its config")
        let controller = StyledTerminalController(ghostty)
        do {
            return try await measure(controller, style: style)
        } catch {
            controller.closeTabImmediately(registerRedo: false)
            throw error
        }
    }

    private static func measure(_ controller: TerminalController, style: TitlebarStyle) async throws -> StyledWindowFixture {
        let window = try #require(controller.window)
        controller.leoSession?.isSidebarVisible = true
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        let (split, sidebar) = try #require(await sidebarHosting(in: window), "\(style): no sidebar in the split")
        // The tracking separator joins once the split hands itself over.
        if let toolbar = window.toolbar {
            try #require(await toolbarIsComplete(toolbar), "\(style): the toolbar never got its separator: \(toolbar.items.map(\.itemIdentifier.rawValue))")
        }
        let frames = HeaderProbe()
        let relative = try #require(await frames.settledHeader(probing: sidebar), "\(style): \(frames)")
        let relativeAccessory = try #require(frames.relativeAccessory, "\(style): \(frames)")
        let host = sidebar.view.convert(sidebar.view.bounds, to: nil)
        // SwiftUI's y runs down from the host's top; the window's runs up.
        let header = CGRect(x: host.minX + relative.minX, y: host.maxY - relative.maxY, width: relative.width, height: relative.height)
        let accessory = CGRect(
            x: host.minX + relativeAccessory.minX, y: host.maxY - relativeAccessory.maxY,
            width: relativeAccessory.width, height: relativeAccessory.height)
        let splitTop = split.splitView.convert(split.splitView.bounds, to: nil).maxY
        let diagnostics = "\(type(of: window)) \(window.frame.size) host \(host) safe area \(sidebar.view.safeAreaInsets) "
            + "split top \(splitTop) header \(header)"
        return StyledWindowFixture(
            controller: controller, window: window, split: split, header: header, accessory: accessory,
            splitTop: splitTop, diagnostics: diagnostics)
    }

    /// Whether the toolbar settles on `LeoAgentToolbar.itemOrder`.
    private static func toolbarIsComplete(_ toolbar: NSToolbar) async -> Bool {
        for _ in 0 ..< 100 {
            if toolbar.items.map(\.itemIdentifier) == LeoAgentToolbar.itemOrder { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// The sidebar's hosting controller, once the split view is built.
    private static func sidebarHosting(in window: NSWindow) async -> (LeoSplitViewController, NSHostingController<AnyView>)? {
        for _ in 0 ..< 50 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let split = window.contentView.flatMap(findSplit),
               let item = split.sidebarItem, !item.isCollapsed,
               let hosting = item.viewController as? NSHostingController<AnyView> {
                return (split, hosting)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private static func findSplit(_ view: NSView) -> LeoSplitViewController? {
        if let split = (view as? NSSplitView)?.delegate as? LeoSplitViewController { return split }
        return view.subviews.lazy.compactMap(findSplit).first
    }
}

/// A `Ghostty.App` whose config sets only the titlebar style, loaded from
/// a temporary file (never the user's config).
@MainActor
private enum StyleConfig {
    static func app(for style: TitlebarStyle, decorations: Bool = true) throws -> Ghostty.App {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leo-b074-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try "macos-titlebar-style = \(style.configValue)\nwindow-decoration = \(decorations)\n".write(to: file, atomically: true, encoding: .utf8)
        let app = Ghostty.App(configPath: file.path)
        try #require(app.config.macosTitlebarStyle.rawValue == style.configValue, "\(style): the config didn't take")
        return app
    }
}

/// Where the header parts and the sidebar's full bounds land, in SwiftUI's
/// global space.
@MainActor
private final class HeaderProbe: CustomStringConvertible {
    /// Wall-clock time between re-probes while there is no reading that
    /// matches the hosting view's size (nothing reported, or the report went
    /// stale). Elapsed time, not a poll count: a stalled main thread (a
    /// loaded host, the suite's earlier windows closing) stretches the
    /// polls, and a count then spaced the re-probes seconds apart (B-368).
    private static let reprobeInterval: Duration = .milliseconds(200)

    /// The sidebar root's frame grown by its safe-area insets: the hosting
    /// view's full bounds. (A background that ignores the safe area does not
    /// reach into it here, which once hid the whole bug.)
    private var host: CGRect?
    private var parts: [LeoSidebarHeaderPart: CGRect] = [:]

    var description: String { "host \(host.map { "\($0)" } ?? "unreported"); parts \(parts)" }

    /// Makes `sidebar` report its header parts and its full bounds here.
    /// The split view reassigns the sidebar's root view whenever SwiftUI
    /// updates it, which can drop the probe before the first layout, so
    /// `settledHeader` re-probes until the frames arrive.
    func probe(_ sidebar: NSHostingController<AnyView>) {
        sidebar.rootView = AnyView(
            sidebar.rootView
                .environment(\.leoSidebarHeaderFrameSink) { [weak self] part, frame in self?.parts[part] = frame }
                .onGeometryChange(for: CGRect.self) { proxy in
                    let frame = proxy.frame(in: .global)
                    let insets = proxy.safeAreaInsets
                    return CGRect(
                        x: frame.minX - insets.leading, y: frame.minY - insets.top,
                        width: frame.width + insets.leading + insets.trailing, height: frame.height + insets.top + insets.bottom)
                } action: { [weak self] in self?.host = $0 })
    }

    /// The header row (title ∪ accessory) relative to the hosting view's
    /// top-left corner, once it has held still for a few polls. Nil if that
    /// never happens, or if the measured host isn't the hosting view's size
    /// (the reference would be wrong).
    /// Re-probes while the reading is missing or stale: the split reassigns
    /// the sidebar's root view on every SwiftUI update, which drops the
    /// probe, so a report from before the sidebar's width settled never
    /// refreshes by itself.
    func settledHeader(probing sidebar: NSHostingController<AnyView>, timeout: Duration = .seconds(10)) async -> CGRect? {
        let deadline = ContinuousClock.now + timeout
        var last: CGRect?
        var stablePolls = 0
        var nextProbe = ContinuousClock.now
        while ContinuousClock.now < deadline {
            let current = relativeHeader.flatMap { host?.size == sidebar.view.bounds.size ? $0 : nil }
            if current == nil, ContinuousClock.now >= nextProbe {
                probe(sidebar)
                sidebar.view.needsLayout = true
                sidebar.view.layoutSubtreeIfNeeded()
                nextProbe = ContinuousClock.now + Self.reprobeInterval
            }
            stablePolls = (current != nil && current == last) ? stablePolls + 1 : 0
            if stablePolls >= 3 { return current }
            last = current
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The accessory (the + button) relative to the hosting view's
    /// top-left corner (B-153).
    var relativeAccessory: CGRect? {
        guard let host, !host.isEmpty, let accessory = parts[.accessory], !accessory.isEmpty else { return nil }
        return accessory.offsetBy(dx: -host.minX, dy: -host.minY)
    }

    private var relativeHeader: CGRect? {
        guard let host, !host.isEmpty, let title = parts[.title], let accessory = parts[.accessory],
              !title.isEmpty, !accessory.isEmpty else { return nil }
        return title.union(accessory).offsetBy(dx: -host.minX, dy: -host.minY)
    }
}
