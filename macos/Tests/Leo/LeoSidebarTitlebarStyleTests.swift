import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-074: the sidebar header against the window's buttons, for every
/// `macos-titlebar-style`. Each test builds a window the way the app does:
/// a `Ghostty.App` loaded from a config file that sets the style (and
/// nothing else), and a real `TerminalController` on it, which picks the
/// style's nib and window subclass itself. The real `LeoSidebarSplit` lays
/// out inside; the header's frame and the window buttons' frames are then
/// compared in window coordinates. The windows are shown, never made key,
/// so AppKit places the titlebar and buttons.
///
/// Needs the test host's `LeoRuntime` and a loadable Ghostty config; either
/// missing fails the test rather than passing it silently.
@MainActor @Suite(.serialized)
struct LeoSidebarTitlebarStyleTests {
    /// How far a header row may sit from where the chrome metrics put it:
    /// the row's height is the button's, so the title is centred in it.
    private static let rowTolerance: CGFloat = 6

    @Test(arguments: TitlebarStyle.allCases)
    func theWindowButtonsNeverOverlapTheSidebarHeader(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }

        for (kind, button) in fixture.visibleWindowButtons {
            #expect(!button.intersects(fixture.header), "\(style): the \(kind) button \(button) overlaps the header; \(fixture.diagnostics)")
        }
    }

    /// Ghostty hides the titlebar and the window buttons in this style, so
    /// the split (sidebar and terminal) runs to the window's top edge and the
    /// header takes the top strip with only the chrome's own inset -- no
    /// room reserved for buttons that aren't drawn.
    @Test func theHiddenStyleDrawsNoButtonsAndReservesNoRoomForThem() async throws {
        let fixture = try await StyledWindowFixture.make(.hidden)
        defer { fixture.close() }

        #expect(fixture.window is HiddenTitlebarTerminalWindow, "\(type(of: fixture.window))")
        #expect(fixture.visibleWindowButtons.isEmpty, "buttons drawn: \(fixture.visibleWindowButtons)")
        #expect(fixture.splitTop == fixture.windowTop, "an empty band above the split: \(fixture.diagnostics)")
        let gap = fixture.windowTop - fixture.header.maxY
        #expect(gap >= LeoSidebarChromeMetrics.topInset - 1, "the header sits \(gap) pt under the window's top edge; \(fixture.diagnostics)")
        #expect(
            gap <= LeoSidebarChromeMetrics.topInset + Self.rowTolerance,
            "the header sits \(gap) pt under the window's top edge; \(fixture.diagnostics)"
        )
    }

    /// The titled styles (the default, `transparent`, among them) keep
    /// D-122's layout: the split starts at the titlebar's bottom edge and
    /// the header clears it by the chrome's top inset.
    @Test(arguments: [TitlebarStyle.native, .transparent, .tabs, .tabsVentura])
    func titledStylesKeepTheHeaderTheChromeInsetBelowTheTitlebar(_ style: TitlebarStyle) async throws {
        let fixture = try await StyledWindowFixture.make(style)
        defer { fixture.close() }

        #expect(fixture.splitTop == fixture.titlebarBottom, "\(style): the split runs under the titlebar; \(fixture.diagnostics)")
        let gap = fixture.titlebarBottom - fixture.header.maxY
        #expect(gap >= LeoSidebarChromeMetrics.topInset - 1, "\(style): the header sits \(gap) pt under the titlebar; \(fixture.diagnostics)")
        #expect(
            gap <= LeoSidebarChromeMetrics.topInset + Self.rowTolerance,
            "\(style): the header sits \(gap) pt under the titlebar; \(fixture.diagnostics)"
        )
    }
}

/// A `macos-titlebar-style` value, plus the pre-Tahoe tabs window, which
/// config can't select on macOS 26 and later.
enum TitlebarStyle: String, CaseIterable, CustomTestStringConvertible {
    case native
    case transparent
    case tabs
    case hidden
    case tabsVentura

    var testDescription: String { rawValue }

    /// The config value that selects this style.
    var configValue: String { self == .tabsVentura ? "tabs" : rawValue }
}

/// The app's own `TerminalController`, except that the pre-Tahoe tabs
/// window is forced for `.tabsVentura`; every other style goes through the
/// controller's own config-driven nib choice.
private final class StyledTerminalController: TerminalController {
    private static let venturaTabsNib = "TerminalTabsTitlebarVentura"
    private let forcesVenturaTabs: Bool

    init(_ ghostty: Ghostty.App, style: TitlebarStyle) {
        forcesVenturaTabs = style == .tabsVentura
        super.init(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var windowNibName: NSNib.Name? { forcesVenturaTabs ? Self.venturaTabsNib : super.windowNibName }

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

    static func make(_ style: TitlebarStyle) async throws -> StyledWindowFixture {
        try #require((NSApp.delegate as? AppDelegate)?.leoRuntime != nil, "the test host has no LeoRuntime")
        let ghostty = try StyleConfig.app(for: style)
        try #require(ghostty.readiness == .ready, "\(style): the Ghostty app didn't load its config")
        let controller = StyledTerminalController(ghostty, style: style)
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
        let frames = HeaderProbe()
        let relative = try #require(await frames.settledHeader(probing: sidebar), "\(style): \(frames)")
        let host = sidebar.view.convert(sidebar.view.bounds, to: nil)
        // SwiftUI's y runs down from the host's top; the window's runs up.
        let header = CGRect(x: host.minX + relative.minX, y: host.maxY - relative.maxY, width: relative.width, height: relative.height)
        let splitTop = split.splitView.convert(split.splitView.bounds, to: nil).maxY
        let diagnostics = "\(type(of: window)) \(window.frame.size) host \(host) safe area \(sidebar.view.safeAreaInsets) "
            + "split top \(splitTop) header \(header)"
        return StyledWindowFixture(
            controller: controller, window: window, split: split, header: header, splitTop: splitTop, diagnostics: diagnostics)
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
    static func app(for style: TitlebarStyle) throws -> Ghostty.App {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("leo-b074-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try "macos-titlebar-style = \(style.configValue)\n".write(to: file, atomically: true, encoding: .utf8)
        let app = Ghostty.App(configPath: file.path)
        try #require(app.config.macosTitlebarStyle.rawValue == style.configValue, "\(style): the config didn't take")
        return app
    }
}

/// Where the header parts and the sidebar's full bounds land, in SwiftUI's
/// global space.
@MainActor
private final class HeaderProbe: CustomStringConvertible {
    /// Polls between re-probes while nothing has reported.
    private static let reprobeInterval = 10

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
    func settledHeader(probing sidebar: NSHostingController<AnyView>, timeout: Duration = .seconds(10)) async -> CGRect? {
        let deadline = ContinuousClock.now + timeout
        var last: CGRect?
        var stablePolls = 0
        var polls = 0
        while ContinuousClock.now < deadline {
            if relativeHeader == nil, polls % Self.reprobeInterval == 0 { probe(sidebar) }
            polls += 1
            let current = relativeHeader.flatMap { host?.size == sidebar.view.bounds.size ? $0 : nil }
            stablePolls = (current != nil && current == last) ? stablePolls + 1 : 0
            if stablePolls >= 3 { return current }
            last = current
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private var relativeHeader: CGRect? {
        guard let host, !host.isEmpty, let title = parts[.title], let accessory = parts[.accessory],
              !title.isEmpty, !accessory.isEmpty else { return nil }
        return title.union(accessory).offsetBy(dx: -host.minX, dy: -host.minY)
    }
}
