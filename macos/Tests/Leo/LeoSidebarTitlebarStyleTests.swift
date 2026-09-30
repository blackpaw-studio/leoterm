import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-074: the sidebar header against the window's buttons, for every
/// `macos-titlebar-style`. Each test builds a real `TerminalController`
/// from that style's nib (so the real window subclass applies its style
/// mask, titlebar and buttons), with the real `LeoSidebarSplit` inside, and
/// compares where the header lands with where the window buttons are, both
/// in window coordinates. The windows are laid out and shown (never made
/// key) so AppKit places the titlebar and buttons.
///
/// Bails out (rather than fails) without the app's real `Ghostty.App`, like
/// the other `TerminalController` integration tests.
@MainActor @Suite(.serialized)
struct LeoSidebarTitlebarStyleTests {
    /// How far a header row may sit from where the chrome metrics put it:
    /// the row's height is the button's, so the title is centred in it.
    private static let rowTolerance: CGFloat = 6

    @Test(arguments: TitlebarStyleNib.allCases)
    func theWindowButtonsNeverOverlapTheSidebarHeader(_ style: TitlebarStyleNib) async throws {
        guard let fixture = try await StyledWindowFixture.make(style) else { return }
        defer { fixture.close() }

        for (kind, button) in fixture.visibleWindowButtons {
            #expect(!button.intersects(fixture.header), "\(style): the \(kind) button \(button) overlaps the header \(fixture.header)")
        }
    }

    /// Ghostty hides the titlebar and the window buttons in this style, so
    /// the split (sidebar and terminal) runs to the window's top edge and the
    /// header takes the top strip with only the chrome's own inset -- no
    /// room reserved for buttons that aren't drawn.
    @Test func theHiddenStyleDrawsNoButtonsAndReservesNoRoomForThem() async throws {
        guard let fixture = try await StyledWindowFixture.make(.hidden) else { return }
        defer { fixture.close() }

        #expect(fixture.visibleWindowButtons.isEmpty, "buttons drawn: \(fixture.visibleWindowButtons)")
        #expect(fixture.splitTop == fixture.windowTop, "an empty band above the split: \(fixture.diagnostics)")
        let gap = fixture.windowTop - fixture.header.maxY
        #expect(gap >= LeoSidebarChromeMetrics.topInset - 1, "the header sits \(gap) pt under the window's top edge")
        #expect(gap <= LeoSidebarChromeMetrics.topInset + Self.rowTolerance, "the header sits \(gap) pt under the window's top edge; \(fixture.diagnostics)")
    }

    /// The titled styles (the default, `transparent`, among them) keep
    /// D-122's layout: the header clears the titlebar's bottom edge by the
    /// chrome's top inset.
    @Test(arguments: [TitlebarStyleNib.native, .transparent, .tabs])
    func titledStylesKeepTheHeaderTheChromeInsetBelowTheTitlebar(_ style: TitlebarStyleNib) async throws {
        guard let fixture = try await StyledWindowFixture.make(style) else { return }
        defer { fixture.close() }

        #expect(fixture.splitTop == fixture.titlebarBottom, "\(style): the split runs under the titlebar: \(fixture.diagnostics)")
        let gap = fixture.titlebarBottom - fixture.header.maxY
        #expect(gap >= LeoSidebarChromeMetrics.topInset - 1, "\(style): the header sits \(gap) pt under the titlebar; \(fixture.diagnostics)")
        #expect(gap <= LeoSidebarChromeMetrics.topInset + Self.rowTolerance, "\(style): the header sits \(gap) pt under the titlebar; \(fixture.diagnostics)")
    }
}

/// The nib `TerminalController.windowNibName` picks for each
/// `macos-titlebar-style` (`tabs` on macOS 26+).
enum TitlebarStyleNib: String, CaseIterable, CustomTestStringConvertible {
    case native = "Terminal"
    case transparent = "TerminalTransparentTitlebar"
    case tabs = "TerminalTabsTitlebarTahoe"
    case hidden = "TerminalHiddenTitlebar"

    var testDescription: String { "\(self)" }
}

/// A `TerminalController` whose window comes from a given style's nib
/// rather than the one the app's config picks.
private final class StyledTerminalController: TerminalController {
    private let styleNib: TitlebarStyleNib

    init(_ ghostty: Ghostty.App, style: TitlebarStyleNib) {
        styleNib = style
        super.init(ghostty, withSurfaceTree: .init(), leoIsPlaceholder: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var windowNibName: NSNib.Name? { styleNib.rawValue }

    /// The nib lives in the app, not in the test bundle this subclass
    /// comes from.
    override var windowNibPath: String? {
        Bundle(for: TerminalController.self).path(forResource: styleNib.rawValue, ofType: "nib")
    }
}

/// A shown, laid-out window of one titlebar style, with the sidebar
/// header's frame and the window buttons' frames in window coordinates.
@MainActor
private struct StyledWindowFixture {
    let controller: TerminalController
    let window: NSWindow
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

    static func make(_ style: TitlebarStyleNib) async throws -> StyledWindowFixture? {
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty, ghostty.readiness == .ready,
              (NSApp.delegate as? AppDelegate)?.leoRuntime != nil else { return nil }
        let controller = StyledTerminalController(ghostty, style: style)
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
        let diagnostics = "window \(window.frame.size) layout \(window.contentLayoutRect) host \(host) "
            + "hostSafeArea \(sidebar.view.safeAreaInsets) header \(header)"
        let splitTop = split.splitView.convert(split.splitView.bounds, to: nil).maxY
        return StyledWindowFixture(controller: controller, window: window, header: header, splitTop: splitTop, diagnostics: diagnostics)
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

/// Where the header parts and the hosting view's full bounds land, in
/// SwiftUI's global space.
@MainActor
private final class HeaderProbe: CustomStringConvertible {
    private var host: CGRect?
    private var parts: [LeoSidebarHeaderPart: CGRect] = [:]

    var description: String { "host \(host.map { "\($0)" } ?? "unreported"); parts \(parts)" }

    func record(_ part: LeoSidebarHeaderPart, _ frame: CGRect) { parts[part] = frame }

    func recordHost(_ frame: CGRect) { host = frame }

    /// Polls between re-probes while nothing has reported.
    private static let reprobeInterval = 10

    /// Makes `sidebar` report its header parts and its full bounds here.
    /// The split view reassigns the sidebar's root view whenever SwiftUI
    /// updates it, which can drop the probe before the first layout, so
    /// `settledHeader` re-probes until the frames arrive.
    func probe(_ sidebar: NSHostingController<AnyView>) {
        sidebar.rootView = AnyView(
            sidebar.rootView
                .environment(\.leoSidebarHeaderFrameSink) { [weak self] part, frame in self?.record(part, frame) }
                .background {
                    Color.clear.ignoresSafeArea()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [weak self] in self?.recordHost($0) }
                })
    }

    /// The header row (title ∪ accessory) relative to the hosting view's
    /// top-left corner, once it has held still for a few polls.
    func settledHeader(probing sidebar: NSHostingController<AnyView>, timeout: Duration = .seconds(10)) async -> CGRect? {
        let deadline = ContinuousClock.now + timeout
        var last: CGRect?
        var stablePolls = 0
        var polls = 0
        while ContinuousClock.now < deadline {
            if relativeHeader == nil, polls % Self.reprobeInterval == 0 { probe(sidebar) }
            polls += 1
            let current = relativeHeader
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
