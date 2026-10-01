import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// Layout invariants for the agents-sidebar split view.
///
/// These drive the real `NSSplitViewController` the app builds, in a real
/// window, because the bug they guard against (a sidebar frozen at its
/// minimum width, with a divider that shows a resize cursor but will not
/// move) is invisible to anything that only checks the configuration values.
@MainActor struct LeoSplitViewRepresentableTests {
    private static let windowWidth: CGFloat = 1_200
    private static let windowHeight: CGFloat = 600
    private static let draggedWidth: CGFloat = 320
    private static let storedWidth: CGFloat = 280

    @Test func sidebarOpensAtItsStoredWidth() {
        let harness = Harness(preferredWidth: Self.storedWidth)

        #expect(abs(harness.sidebarWidth - Self.storedWidth) <= 1)
    }

    @Test func dividerMovesTheSidebarAwayFromItsMinimumWidth() {
        let harness = Harness()

        harness.dragDivider(to: Self.draggedWidth)

        #expect(abs(harness.sidebarWidth - Self.draggedWidth) <= 1)
    }

    @Test func sidebarKeepsItsDraggedWidthAcrossDetailUpdates() {
        let harness = Harness()
        harness.dragDivider(to: Self.draggedWidth)

        // Every SwiftUI body evaluation reassigns the hosting controllers'
        // root views; that must not disturb the width the user dragged to.
        harness.reassignDetailRootView()

        #expect(abs(harness.sidebarWidth - Self.draggedWidth) <= 1)
    }

    @Test func terminalAbsorbsWindowResizesSoTheSidebarKeepsItsWidth() {
        let harness = Harness()
        harness.dragDivider(to: Self.draggedWidth)

        harness.resizeWindow(toWidth: Self.windowWidth + 200)

        #expect(abs(harness.sidebarWidth - Self.draggedWidth) <= 1)
    }

    // MARK: Editor pane (B-004)

    @Test func theEditorPaneStartsCollapsedWithoutMovingTheSidebar() {
        let harness = Harness(preferredWidth: Self.storedWidth, editor: Self.makeEditor())

        #expect(harness.components.controller.splitViewItems.count == 3)
        #expect(harness.editorItem?.isCollapsed == true)
        #expect(abs(harness.sidebarWidth - Self.storedWidth) <= 1)
    }

    @Test func openingAFileShowsThePaneBesideTheTerminalAndClosingHidesIt() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let editor = Self.makeEditor()
        let harness = Harness(preferredWidth: Self.storedWidth, editor: editor)

        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await harness.settle()

        #expect(harness.editorItem?.isCollapsed == false)
        let editorWidth = harness.editorWidth
        #expect(editorWidth >= LeoEditorPaneViewController.minimumWidth)
        #expect(abs(harness.sidebarWidth - Self.storedWidth) <= 1)

        // The terminal, not the editor, absorbs a window resize.
        harness.resizeWindow(toWidth: Self.windowWidth + 200)
        #expect(abs(harness.editorWidth - editorWidth) <= 1)

        await editor.close()
        await harness.settle()
        #expect(harness.editorItem?.isCollapsed == true)
    }

    // MARK: Opening width (B-022, D-038)

    /// The editor opens at half the width it shares with the terminal --
    /// not at its minimum -- without moving the sidebar, and then keeps
    /// that width while the terminal absorbs a window resize.
    @Test(arguments: [false, true])
    func theEditorOpensAtHalfTheWidthItSharesWithTheTerminal(besideAClosedBrowser: Bool) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let editor = Self.makeEditor()
        let harness = Harness(preferredWidth: Self.storedWidth, editor: editor, browser: besideAClosedBrowser ? Self.makeBrowser() : nil)

        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await harness.settle()
        await harness.settle()

        #expect(harness.editorWidth > LeoEditorPaneViewController.minimumWidth + 100)
        #expect(abs(harness.editorWidth - harness.terminalWidth) <= 1)
        #expect(abs(harness.sidebarWidth - Self.storedWidth) <= 1)
        let editorWidth = harness.editorWidth
        harness.resizeWindow(toWidth: Self.windowWidth + 200)
        #expect(abs(harness.editorWidth - editorWidth) <= 1)
        #expect(harness.browserItem?.isCollapsed ?? true)

        // Another file in the open pane keeps the width it has.
        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("b.swift", "let b = 2")))
        await harness.settle()
        await harness.settle()
        #expect(abs(harness.editorWidth - editorWidth) <= 1)
        await editor.close()
    }

    /// A file opened before the split is in a window: the pane opens at
    /// half once the split first lays out there (setPosition does nothing
    /// before that).
    @Test func anEditorOpenedBeforeTheSplitIsInAWindowStillOpensAtHalf() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let editor = Self.makeEditor()
        let component = LeoSplitViewControllerFactory.make(
            isSidebarVisible: true, preferredWidth: Self.storedWidth, onDividerWidthChange: { _ in },
            sidebar: AnyView(Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)),
            detail: AnyView(Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)), editor: editor)
        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = component.controller
        window.setContentSize(NSSize(width: Self.windowWidth, height: Self.windowHeight))
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<2 {
            window.layoutIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        window.layoutIfNeeded()

        let panes = component.controller.splitView.arrangedSubviews
        #expect(panes.count == 3)
        #expect(panes.last.map { $0.frame.width > LeoEditorPaneViewController.minimumWidth + 100 } == true)
        #expect(abs((panes.last?.frame.width ?? 0) - panes[1].frame.width) <= 1)
        window.orderOut(nil)
        await editor.close()
    }

    /// Beside the browser, the half is of what the terminal and the editor
    /// share; the browser keeps its width.
    @Test func besideTheBrowserTheEditorHalvesWhatItSharesWithTheTerminal() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let browser = Self.makeBrowser()
        let editor = Self.makeEditor()
        let harness = Harness(preferredWidth: LeoSidebarSplitMetrics.minimumWidth, windowWidth: 1_600, editor: editor, browser: browser)
        await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        await harness.settle()
        let browserWidth = harness.browserWidth

        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await harness.settle()
        await harness.settle()

        #expect(harness.sidebarItem?.isCollapsed == false)
        #expect(abs(harness.browserWidth - browserWidth) <= 1)
        #expect(abs(harness.editorWidth - harness.terminalWidth) <= 1)
        #expect(harness.editorWidth > LeoEditorPaneViewController.minimumWidth)
        await editor.close()
        await browser.close()
    }

    /// Half never takes the terminal under its floor: at most what's left
    /// above it, and never under the editor's own minimum.
    @Test func theOpeningWidthKeepsTheTerminalFloor() {
        let minimum = LeoEditorPaneViewController.minimumWidth
        let floor = LeoSidebarSplitMetrics.terminalFloor
        #expect(LeoSidebarSplitMetrics.openingPaneWidth(sharedWidth: 1_000, minimum: minimum) == 500)
        #expect(LeoSidebarSplitMetrics.openingPaneWidth(sharedWidth: 1_001, minimum: minimum) == 500)
        #expect(LeoSidebarSplitMetrics.openingPaneWidth(sharedWidth: 630, minimum: minimum) == minimum)
        #expect(LeoSidebarSplitMetrics.openingPaneWidth(sharedWidth: 500, minimum: minimum) == minimum)
        #expect(LeoSidebarSplitMetrics.openingPaneWidth(sharedWidth: 700, minimum: 100) == 350)
        #expect(LeoSidebarSplitMetrics.openingPaneWidth(sharedWidth: 700, minimum: 390) == 390)
        #expect(LeoSidebarSplitMetrics.openingPaneWidth(sharedWidth: 500, minimum: 100) == 500 - floor)
    }

    @Test func holdingPrioritiesLetTheTerminalAbsorbResizes() {
        let terminal = LeoSidebarSplitMetrics.detailHoldingPriority
        let editor = LeoSidebarSplitMetrics.editorHoldingPriority
        let browser = LeoSidebarSplitMetrics.browserHoldingPriority
        let sidebar = LeoSidebarSplitMetrics.sidebarHoldingPriority
        #expect(terminal < editor && editor < sidebar)
        #expect(terminal < browser && browser < sidebar)
        // NSSplitView's low band: higher freezes the pane (see LeoSidebarSplitMetrics).
        #expect(editor.rawValue >= 250 && editor.rawValue <= 260)
        #expect(browser.rawValue >= 250 && browser.rawValue <= 260)
    }

    // MARK: Workspace browser (B-005)

    @Test func theBrowserSitsOnTheEditorsLeadingEdgeAndStartsCollapsed() {
        let harness = Harness(preferredWidth: Self.storedWidth, editor: Self.makeEditor(), browser: Self.makeBrowser())

        let items = harness.components.controller.splitViewItems
        #expect(items.count == 4)
        #expect(items[2].viewController is LeoWorkspaceBrowserViewController)
        #expect(items[3].viewController is LeoEditorPaneViewController)
        #expect(harness.browserItem?.isCollapsed == true)
        #expect(abs(harness.sidebarWidth - Self.storedWidth) <= 1)
    }

    /// The browser can open (or close) before the split view loads its
    /// views: loading the browser's view must not collapse or expand its
    /// own split item, which `NSSplitViewController` can't take mid-load.
    @Test func theBrowserChangingBeforeTheSplitLoadsDoesNotCrash() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let opened = Self.makeBrowser()
        let closed = Self.makeBrowser()
        await closed.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        let components = [opened, closed].map { browser in
            LeoSplitViewControllerFactory.make(
                isSidebarVisible: true, preferredWidth: Self.storedWidth, onDividerWidthChange: { _ in },
                sidebar: AnyView(Color.clear), detail: AnyView(Color.clear), editor: Self.makeEditor(), browser: browser)
        }
        await opened.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        await closed.close()

        for (index, component) in components.enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = component.controller
            window.setContentSize(NSSize(width: Self.windowWidth, height: Self.windowHeight))
            window.layoutIfNeeded()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.layoutIfNeeded()
            let item = component.controller.splitViewItems.first { $0.viewController is LeoWorkspaceBrowserViewController }
            #expect(item?.isCollapsed == (index == 1))
            window.close()
        }
        await opened.close()
    }

    // MARK: Terminal floor (D-036)

    /// Opening the editor beside the browser would leave the terminal
    /// under its floor: the sidebar collapses first, and says so. The
    /// browser alone fits, so it doesn't.
    @Test func openingAPaneThatWouldSqueezeTheTerminalCollapsesTheSidebarFirst() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let browser = Self.makeBrowser()
        let editor = Self.makeEditor()
        var autoCollapses = 0
        let harness = Harness(
            preferredWidth: LeoSidebarSplitMetrics.minimumWidth, windowWidth: 1_000, editor: editor, browser: browser,
            onSidebarAutoCollapse: { autoCollapses += 1 })

        await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        await harness.settle()
        #expect(harness.sidebarItem?.isCollapsed == false)
        #expect(autoCollapses == 0)

        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await harness.settle()

        #expect(harness.editorItem?.isCollapsed == false)
        #expect(harness.sidebarItem?.isCollapsed == true)
        #expect(autoCollapses == 1)
        #expect(harness.terminalWidth >= LeoSidebarSplitMetrics.terminalFloor)
        await editor.close()
        await browser.close()
    }

    /// At 800pt, even without the sidebar the terminal is short of its
    /// floor: the pane opens anyway and the terminal gives way down to its
    /// minimum -- the user's action is never refused.
    @Test func whenTheTerminalIsStillShortThePaneOpensAnyway() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let browser = Self.makeBrowser()
        let editor = Self.makeEditor()
        let harness = Harness(preferredWidth: LeoSidebarSplitMetrics.minimumWidth, windowWidth: 800, editor: editor, browser: browser)
        await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        await harness.settle()
        #expect(harness.terminalWidth >= LeoSidebarSplitMetrics.terminalFloor, "the browser alone fits beside the sidebar")

        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await harness.settle()

        #expect(harness.editorItem?.isCollapsed == false)
        #expect(harness.browserItem?.isCollapsed == false)
        #expect(harness.sidebarItem?.isCollapsed == true)
        #expect(harness.editorWidth >= LeoEditorPaneViewController.minimumWidth - 1)
        #expect(harness.browserWidth >= LeoWorkspaceBrowserViewController.minimumWidth - 1)
        #expect(harness.terminalWidth >= LeoSidebarSplitMetrics.minimumTerminalWidth)
        #expect(harness.terminalWidth > 200, "only the sidebar gave way, not the terminal down to its minimum")
        await editor.close()
        await browser.close()
    }

    /// With room to spare, the sidebar stays.
    @Test func aWideWindowKeepsTheSidebar() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let browser = Self.makeBrowser()
        let editor = Self.makeEditor()
        var autoCollapses = 0
        let harness = Harness(
            preferredWidth: LeoSidebarSplitMetrics.minimumWidth, windowWidth: 1_400, editor: editor, browser: browser,
            onSidebarAutoCollapse: { autoCollapses += 1 })

        await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await harness.settle()

        #expect(harness.sidebarItem?.isCollapsed == false)
        #expect(autoCollapses == 0)
        #expect(harness.terminalWidth >= LeoSidebarSplitMetrics.terminalFloor)
        await editor.close()
        await browser.close()
    }

    // MARK: Terminal floor on resize and re-show (D-058)

    /// How often the split collapsed or restored the sidebar for the floor.
    @MainActor private final class FloorCounts {
        var collapses = 0
        var restores = 0
    }

    /// Both side panes open in a 1 400 pt window, the sidebar (shown
    /// unless `sidebarVisible` is false) at its minimum beside them.
    private func withBothPanes(
        sidebarVisible: Bool = true, opensBrowser: Bool = true,
        _ body: (Harness, LeoWorkspaceBrowserModel, LeoEditorPaneModel, FloorCounts) async throws -> Void
    ) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let browser = Self.makeBrowser()
        let editor = Self.makeEditor()
        let counts = FloorCounts()
        let harness = Harness(
            preferredWidth: LeoSidebarSplitMetrics.minimumWidth, windowWidth: 1_400, isSidebarVisible: sidebarVisible,
            editor: editor, browser: browser,
            onSidebarAutoCollapse: { counts.collapses += 1 }, onSidebarAutoRestore: { counts.restores += 1 })
        if opensBrowser {
            await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        }
        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await harness.settle()
        if !sidebarVisible {
            // The factory's first width shows it on layout; the
            // representable's next update hides it again, as here.
            harness.sidebarItem?.isCollapsed = true
            await harness.settle()
        }
        try #require(harness.sidebarItem?.isCollapsed == !sidebarVisible)
        try await body(harness, browser, editor, counts)
        await editor.close()
        await browser.close()
    }

    /// Narrowing the window collapses the sidebar before the terminal goes
    /// under its floor, once.
    @Test func narrowingTheWindowCollapsesTheSidebarToKeepTheTerminalFloor() async throws {
        try await withBothPanes { harness, _, _, counts in
            let editorWidth = harness.editorWidth

            await harness.resizeWindow(stepwiseTo: 1_100)

            #expect(harness.sidebarItem?.isCollapsed == true)
            #expect(counts.collapses == 1)
            #expect(harness.terminalWidth >= LeoSidebarSplitMetrics.terminalFloor)
            #expect(abs(harness.editorWidth - editorWidth) <= 1, "the terminal absorbed the rest")
        }
    }

    /// Beside the editor alone (the browser collapsed between them), the
    /// terminal keeps its floor down to where the editor is at its
    /// minimum: 300 + 1 + 320 = 621 pt. Live resizes step by 5 pt or by
    /// 40; a jump (zoom, tiling) goes there at once.
    @Test(arguments: [[700], [900, 700], [621]] as [[CGFloat]], [5, 40, 0] as [CGFloat])
    func besideTheEditorAloneTheFloorHoldsToTheEditorsMinimum(_ path: [CGFloat], step: CGFloat) async throws {
        try await withBothPanes(opensBrowser: false) { harness, _, _, _ in
            for width in path {
                if step == 0 {
                    harness.resizeWindow(toWidth: width)
                    await harness.settle()
                    await harness.settle()
                } else {
                    await harness.resizeWindow(stepwiseTo: width, step: step)
                }
            }

            #expect(harness.sidebarItem?.isCollapsed == true)
            #expect(harness.terminalWidth >= LeoSidebarSplitMetrics.terminalFloor - 1, "terminal \(harness.terminalWidth)")
            #expect(harness.editorWidth >= LeoEditorPaneViewController.minimumWidth - 1)
        }
    }

    /// Past that, the side panes give way down to their minimums before
    /// the terminal goes under its floor; widening again goes to the
    /// terminal.
    @Test func narrowingFurtherMakesTheSidePanesGiveWayThenTheTerminal() async throws {
        try await withBothPanes { harness, _, _, _ in
            let step = Harness.resizeStep

            await harness.resizeWindow(stepwiseTo: 900)
            #expect(abs(harness.terminalWidth - LeoSidebarSplitMetrics.terminalFloor) <= 1)
            #expect(harness.editorWidth < 500, "the editor gave way")

            await harness.resizeWindow(stepwiseTo: 700)
            #expect(abs(harness.editorWidth - LeoEditorPaneViewController.minimumWidth) <= 1)
            #expect(abs(harness.browserWidth - LeoWorkspaceBrowserViewController.minimumWidth) <= 1)
            #expect(harness.terminalWidth < LeoSidebarSplitMetrics.terminalFloor)

            let editorWidth = harness.editorWidth
            let terminalWidth = harness.terminalWidth
            await harness.resizeWindow(stepwiseTo: 800)
            #expect(harness.terminalWidth >= terminalWidth + 100 - step, "widening goes to the terminal")
            #expect(harness.editorWidth <= editorWidth + step)
        }
    }

    /// A divider drag doesn't narrow the window: the sidebar stays where
    /// the user put it.
    @Test func draggingTheSidebarDividerDoesNotCollapseIt() async throws {
        try await withBothPanes { harness, _, _, counts in
            harness.dragDivider(to: LeoSidebarSplitMetrics.maximumWidth)
            await harness.settle()

            #expect(harness.sidebarItem?.isCollapsed == false)
            #expect(counts.collapses == 0)
        }
    }

    /// Re-showing the sidebar (⌘⇧L) where it would squeeze the terminal
    /// is refused; with room, or without a side pane, it's allowed.
    @Test func theSidebarIsReShownOnlyWhereItKeepsTheTerminalFloor() async throws {
        try await withBothPanes { harness, browser, editor, _ in
            let controller = harness.components.controller
            #expect(!controller.sidebarSqueezesTerminal(atWidth: LeoSidebarSplitMetrics.minimumWidth))

            await harness.resizeWindow(stepwiseTo: 1_100)
            try #require(harness.sidebarItem?.isCollapsed == true)
            #expect(controller.sidebarSqueezesTerminal(atWidth: LeoSidebarSplitMetrics.minimumWidth))

            await editor.close()
            await browser.close()
            await harness.settle()
            #expect(!controller.sidebarSqueezesTerminal(atWidth: LeoSidebarSplitMetrics.maximumWidth))
        }
    }

    // MARK: Widening again (D-059)

    /// A sidebar collapsed by the floor is transient: widening back gives
    /// the editor its width back first, then the sidebar returns, and the
    /// window ends as it began.
    @Test func wideningBackRestoresTheSidebarAndTheEditorsWidth() async throws {
        try await withBothPanes { harness, _, _, counts in
            let widths = (harness.sidebarWidth, harness.terminalWidth, harness.browserWidth, harness.editorWidth)

            await harness.resizeWindow(stepwiseTo: 700)
            await harness.resizeWindow(stepwiseTo: 1_400)

            #expect(harness.sidebarItem?.isCollapsed == false)
            #expect((counts.collapses, counts.restores) == (1, 1))
            #expect(abs(harness.sidebarWidth - widths.0) <= 1)
            #expect(abs(harness.terminalWidth - widths.1) <= 1)
            #expect(abs(harness.browserWidth - widths.2) <= 1)
            #expect(abs(harness.editorWidth - widths.3) <= 1)
        }
    }

    /// A jump (zoom, tiling) rather than a live resize: 1 400 → 700 →
    /// 1 400 pt at once still gives the editor its width back and brings
    /// the sidebar back (B-037), beside the browser or not.
    @Test(arguments: [true, false])
    func wideningBackInOneJumpRestoresTheSidebarAndTheEditorsWidth(opensBrowser: Bool) async throws {
        try await withBothPanes(opensBrowser: opensBrowser) { harness, _, _, counts in
            let widths = (harness.sidebarWidth, harness.terminalWidth, harness.editorWidth)

            await harness.jumpWindow(to: 700)
            try #require(harness.sidebarItem?.isCollapsed == true)
            await harness.jumpWindow(to: 1_400)

            #expect(harness.sidebarItem?.isCollapsed == false)
            #expect((counts.collapses, counts.restores) == (1, 1))
            #expect(abs(harness.sidebarWidth - widths.0) <= 1)
            #expect(abs(harness.terminalWidth - widths.1) <= 1)
            #expect(abs(harness.editorWidth - widths.2) <= 1)
        }
    }

    /// With only the sidebar collapsed (no pane squeezed), one jump wider
    /// brings it back.
    @Test func aJumpWiderRestoresASidebarCollapsedAlone() async throws {
        try await withBothPanes { harness, _, _, counts in
            let editorWidth = harness.editorWidth
            await harness.resizeWindow(stepwiseTo: 1_100)
            try #require(harness.sidebarItem?.isCollapsed == true)
            try #require(abs(harness.editorWidth - editorWidth) <= 1)

            await harness.jumpWindow(to: 1_400)

            #expect(harness.sidebarItem?.isCollapsed == false)
            #expect((counts.collapses, counts.restores) == (1, 1))
        }
    }

    /// The editor grows back before the terminal takes any of the extra.
    @Test func theSqueezedEditorGrowsBackBeforeTheTerminal() async throws {
        try await withBothPanes { harness, _, _, _ in
            await harness.resizeWindow(stepwiseTo: 900)
            let editorWidth = harness.editorWidth

            await harness.resizeWindow(stepwiseTo: 950)

            #expect(abs(harness.editorWidth - (editorWidth + 50)) <= 1)
            #expect(abs(harness.terminalWidth - LeoSidebarSplitMetrics.terminalFloor) <= 1)
        }
    }

    /// Jiggling the window at the width where the sidebar collapsed
    /// doesn't flip it back and forth.
    @Test func jigglingAtTheCollapseEdgeDoesNotOscillate() async throws {
        try await withBothPanes { harness, _, _, counts in
            var width = harness.window.contentLayoutRect.width
            while harness.sidebarItem?.isCollapsed == false, width > 900 {
                width -= Harness.resizeStep
                await harness.resizeWindow(stepwiseTo: width)
            }
            try #require(counts.collapses == 1)

            for _ in 0..<5 {
                await harness.resizeWindow(stepwiseTo: width + Harness.resizeStep)
                await harness.resizeWindow(stepwiseTo: width)
            }

            #expect(harness.sidebarItem?.isCollapsed == true)
            #expect((counts.collapses, counts.restores) == (1, 0))
        }
    }

    /// A sidebar the user hid stays hidden however wide the window gets.
    @Test func aSidebarTheUserHidStaysHidden() async throws {
        try await withBothPanes(sidebarVisible: false) { harness, _, _, counts in
            let editorWidth = harness.editorWidth

            await harness.resizeWindow(stepwiseTo: 800)
            await harness.resizeWindow(stepwiseTo: 1_600)

            #expect(harness.sidebarItem?.isCollapsed == true)
            #expect((counts.collapses, counts.restores) == (0, 0))
            #expect(abs(harness.editorWidth - editorWidth) <= 1)
        }
    }

    @Test func openingTheBrowserShowsItAndClosingHidesIt() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.file("a.swift", "")
        let browser = Self.makeBrowser()
        let harness = Harness(preferredWidth: Self.storedWidth, editor: Self.makeEditor(), browser: browser)

        await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        await harness.settle()

        #expect(harness.browserItem?.isCollapsed == false)
        let width = harness.browserWidth
        #expect(width >= LeoWorkspaceBrowserViewController.minimumWidth)
        #expect(abs(harness.sidebarWidth - Self.storedWidth) <= 1)
        #expect(harness.editorItem?.isCollapsed == true, "the editor stays closed until a file opens")

        harness.resizeWindow(toWidth: Self.windowWidth + 200)
        #expect(abs(harness.browserWidth - width) <= 1, "the terminal absorbs a window resize")

        await browser.close()
        await harness.settle()
        #expect(harness.browserItem?.isCollapsed == true)
    }

    // MARK: Width across launches (B-084)

    private static let relaunchedWidth: CGFloat = 360

    /// Builds the split as the app does at launch: from a window session
    /// reading `defaults`, persisting divider moves back through it.
    private static func launch(
        _ defaults: UserDefaults, attachesAfterAMainQueueTurn: Bool = false, isSidebarVisible: Bool = true,
        windowWidth: CGFloat = LeoSplitViewRepresentableTests.windowWidth
    ) async -> Harness {
        let session = LeoWindowSession(defaults: defaults)
        let harness = Harness(
            preferredWidth: session.preferredWidth, windowWidth: windowWidth, isSidebarVisible: isSidebarVisible,
            onDividerWidthChange: { session.setPreferredWidth($0) }, attachesWindow: !attachesAfterAMainQueueTurn)
        if attachesAfterAMainQueueTurn {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            harness.attachWindow()
        }
        for _ in 0..<3 { await harness.settle() }
        return harness
    }

    /// Opening a window restores the stored width and leaves it stored:
    /// the layout that applies it isn't the user's drag.
    @Test(arguments: [false, true])
    func launchingDoesNotOverwriteTheStoredSidebarWidth(attachesAfterAMainQueueTurn: Bool) async {
        let defaults = LeoInMemoryDefaults()
        defaults.set(Double(Self.relaunchedWidth), forKey: LeoWindowSession.sidebarWidthKey)

        let harness = await Self.launch(defaults, attachesAfterAMainQueueTurn: attachesAfterAMainQueueTurn)
        defer { harness.close() }

        #expect(defaults.double(forKey: LeoWindowSession.sidebarWidthKey) == Double(Self.relaunchedWidth))
        #expect(abs(harness.sidebarWidth - Self.relaunchedWidth) <= 1)
    }

    /// The width the user dragged to is the one the next launch opens at,
    /// whichever turn the first launch's window arrived on: the guard on
    /// the layouts that restore the width drops once it's applied.
    @Test(arguments: [false, true])
    func aDraggedWidthSurvivesARelaunch(attachesAfterAMainQueueTurn: Bool) async {
        let defaults = LeoInMemoryDefaults()
        defaults.set(240.0, forKey: LeoWindowSession.sidebarWidthKey)
        let draggedWidth: CGFloat = 330

        let first = await Self.launch(defaults, attachesAfterAMainQueueTurn: attachesAfterAMainQueueTurn)
        #expect(!first.components.controller.isApplyingProgrammaticWidth)
        first.dragDivider(to: draggedWidth)
        await first.settle()
        first.close()
        await first.settle()
        let relaunched = await Self.launch(defaults, attachesAfterAMainQueueTurn: true)
        defer { relaunched.close() }

        #expect(abs(relaunched.sidebarWidth - draggedWidth) <= 1)
        #expect(abs(defaults.double(forKey: LeoWindowSession.sidebarWidthKey) - Double(draggedWidth)) <= 1)
    }

    /// A window too narrow for the stored width clamps the sidebar. What
    /// it records is the width the sidebar got, not the one asked for, so
    /// widening the window afterwards stores nothing: the stored width is
    /// still the one the next launch opens at (B-089).
    @Test(arguments: [false, true])
    func aNarrowLaunchThenWidenKeepsTheStoredWidth(attachesAfterAMainQueueTurn: Bool) async {
        let defaults = LeoInMemoryDefaults()
        let storedWidth = LeoSidebarSplitMetrics.maximumWidth
        defaults.set(Double(storedWidth), forKey: LeoWindowSession.sidebarWidthKey)
        let harness = await Self.launch(
            defaults, attachesAfterAMainQueueTurn: attachesAfterAMainQueueTurn, windowWidth: Self.narrowWindowWidth)
        defer { harness.close() }
        let controller = harness.components.controller
        // Clamped: the terminal keeps its minimum beside it.
        #expect(harness.sidebarWidth < storedWidth - 1)
        #expect(abs(controller.lastPersistedWidth - harness.sidebarWidth) <= 1)

        await harness.jumpWindow(to: Self.windowWidth)

        #expect(defaults.double(forKey: LeoWindowSession.sidebarWidthKey) == Double(storedWidth))
    }

    /// Narrower than the stored maximum width plus the terminal's minimum.
    private static let narrowWindowWidth: CGFloat = 320

    /// A sidebar hidden at launch opens at the stored width when shown,
    /// and showing it stores nothing new.
    @Test func aHiddenSidebarShownAfterLaunchOpensAtTheStoredWidth() async throws {
        let defaults = LeoInMemoryDefaults()
        defaults.set(Double(Self.relaunchedWidth), forKey: LeoWindowSession.sidebarWidthKey)
        let harness = await Self.launch(defaults, attachesAfterAMainQueueTurn: true, isSidebarVisible: false)
        defer { harness.close() }
        let controller = harness.components.controller
        let sidebarItem = try #require(harness.sidebarItem)
        // Still hidden: launching didn't un-collapse it (B-090).
        try #require(sidebarItem.isCollapsed)

        // As the representable shows one (⌘⇧L), with the session's width.
        controller.isApplyingProgrammaticWidth = true
        sidebarItem.isCollapsed = false
        controller.applyProgrammaticWidth(Self.relaunchedWidth)
        for _ in 0..<3 { await harness.settle() }

        #expect(abs(harness.sidebarWidth - Self.relaunchedWidth) <= 1)
        #expect(defaults.double(forKey: LeoWindowSession.sidebarWidthKey) == Double(Self.relaunchedWidth))
    }

    // MARK: Hidden at launch (B-090)

    /// A sidebar hidden at launch stays collapsed through the layouts that
    /// restore the stored width: never un-collapsed, not even for one
    /// layout (the representable's next update would then re-collapse it
    /// with an animation), and nothing stored.
    @Test(arguments: [false, true])
    func aSidebarHiddenAtLaunchStaysCollapsed(attachesAfterAMainQueueTurn: Bool) async throws {
        let defaults = LeoInMemoryDefaults()
        defaults.set(Double(Self.relaunchedWidth), forKey: LeoWindowSession.sidebarWidthKey)
        let session = LeoWindowSession(defaults: defaults)
        let harness = Harness(
            preferredWidth: session.preferredWidth, isSidebarVisible: false,
            onDividerWidthChange: { session.setPreferredWidth($0) }, attachesWindow: false)
        defer { harness.close() }
        let sidebarItem = try #require(harness.sidebarItem)
        var collapsedTrace: [Bool] = []
        let observation = sidebarItem.observe(\.isCollapsed, options: [.initial, .new]) { item, _ in
            collapsedTrace.append(item.isCollapsed)
        }
        defer { observation.invalidate() }

        if attachesAfterAMainQueueTurn {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        harness.attachWindow()
        for _ in 0..<3 { await harness.settle() }

        #expect(collapsedTrace.allSatisfy { $0 }, "isCollapsed trace: \(collapsedTrace)")
        #expect(sidebarItem.isCollapsed)
        // The terminal has the whole split: no sidebar pixels showing.
        #expect(abs(harness.terminalWidth - harness.components.controller.splitView.bounds.width) <= 1)
        #expect(defaults.double(forKey: LeoWindowSession.sidebarWidthKey) == Double(Self.relaunchedWidth))
    }

    private static func makeEditor() -> LeoEditorPaneModel {
        LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
    }

    private static func makeBrowser() -> LeoWorkspaceBrowserModel {
        LeoWorkspaceBrowserModel(makeAccess: { _ in LeoFileAccessor.local() }, openFile: { _ in .opened })
    }

    /// A live split view controller inside a real, correctly sized window.
    @MainActor private final class Harness {
        let components: (controller: LeoSplitViewController,
                         sidebarHosting: NSHostingController<AnyView>,
                         detailHosting: NSHostingController<AnyView>)
        let window: NSWindow

        private let windowWidth: CGFloat

        /// `attachesWindow: false` leaves the split out of any window until
        /// `attachWindow()`, as the app's SwiftUI hosting view does for a
        /// main-queue turn after building it.
        init(
            preferredWidth: CGFloat = 240, windowWidth: CGFloat = LeoSplitViewRepresentableTests.windowWidth,
            isSidebarVisible: Bool = true, editor: LeoEditorPaneModel? = nil, browser: LeoWorkspaceBrowserModel? = nil,
            onSidebarAutoCollapse: @escaping () -> Void = {}, onSidebarAutoRestore: @escaping () -> Void = {},
            onDividerWidthChange: @escaping (CGFloat) -> Void = { _ in }, attachesWindow: Bool = true
        ) {
            components = LeoSplitViewControllerFactory.make(
                isSidebarVisible: isSidebarVisible,
                preferredWidth: preferredWidth,
                onDividerWidthChange: onDividerWidthChange,
                sidebar: Self.flexibleView(),
                detail: Self.flexibleView(),
                editor: editor,
                browser: browser,
                onSidebarAutoCollapse: onSidebarAutoCollapse,
                onSidebarAutoRestore: onSidebarAutoRestore)

            self.windowWidth = windowWidth
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: LeoSplitViewRepresentableTests.windowHeight),
                styleMask: [.titled],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            if attachesWindow { attachWindow() }
        }

        func attachWindow() {
            window.contentViewController = components.controller
            // Assigning `contentViewController` shrinks the window to that
            // controller's fitting size, which would leave the split view far
            // too narrow for the divider to have anywhere to travel.
            window.setContentSize(NSSize(width: windowWidth, height: LeoSplitViewRepresentableTests.windowHeight))
            window.makeKeyAndOrderFront(nil)
            layout()
        }

        /// The window closes, as at quit.
        func close() {
            window.close()
        }

        var sidebarWidth: CGFloat { components.sidebarHosting.view.frame.width }

        var sidebarItem: NSSplitViewItem? { components.controller.sidebarItem }

        var terminalWidth: CGFloat { components.detailHosting.view.frame.width }

        var editorItem: NSSplitViewItem? {
            components.controller.splitViewItems.first { $0.viewController is LeoEditorPaneViewController }
        }

        var editorWidth: CGFloat { editorItem?.viewController.view.frame.width ?? 0 }

        var browserItem: NSSplitViewItem? {
            components.controller.splitViewItems.first { $0.viewController is LeoWorkspaceBrowserViewController }
        }

        var browserWidth: CGFloat { browserItem?.viewController.view.frame.width ?? 0 }

        /// Lets the pane's main-queue model subscriptions run, then lays out.
        func settle() async {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            layout()
        }

        func dragDivider(to width: CGFloat) {
            components.controller.splitView.setPosition(width, ofDividerAt: 0)
            layout()
        }

        func reassignDetailRootView() {
            components.detailHosting.rootView = Self.flexibleView()
            layout()
        }

        func resizeWindow(toWidth width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: LeoSplitViewRepresentableTests.windowHeight))
            layout()
        }

        static let resizeStep: CGFloat = 5

        /// A live resize: `resizeStep` at a time, settling after each.
        func resizeWindow(stepwiseTo width: CGFloat, step: CGFloat = resizeStep) async {
            var current = window.contentLayoutRect.width
            while abs(width - current) > 0.5 {
                current += max(-step, min(step, width - current))
                resizeWindow(toWidth: current)
                await settle()
            }
        }

        /// A resize in one go (zoom, tiling), then the floor's follow-ups.
        func jumpWindow(to width: CGFloat) async {
            resizeWindow(toWidth: width)
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
