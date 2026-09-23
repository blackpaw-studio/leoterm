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

        init(
            preferredWidth: CGFloat = 240, windowWidth: CGFloat = LeoSplitViewRepresentableTests.windowWidth,
            editor: LeoEditorPaneModel? = nil, browser: LeoWorkspaceBrowserModel? = nil, onSidebarAutoCollapse: @escaping () -> Void = {}
        ) {
            components = LeoSplitViewControllerFactory.make(
                isSidebarVisible: true,
                preferredWidth: preferredWidth,
                onDividerWidthChange: { _ in },
                sidebar: Self.flexibleView(),
                detail: Self.flexibleView(),
                editor: editor,
                browser: browser,
                onSidebarAutoCollapse: onSidebarAutoCollapse)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: LeoSplitViewRepresentableTests.windowHeight),
                styleMask: [.titled],
                backing: .buffered,
                defer: false)
            window.contentViewController = components.controller
            // Assigning `contentViewController` shrinks the window to that
            // controller's fitting size, which would leave the split view far
            // too narrow for the divider to have anywhere to travel.
            window.setContentSize(NSSize(width: windowWidth, height: LeoSplitViewRepresentableTests.windowHeight))
            window.makeKeyAndOrderFront(nil)
            layout()
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

        private func layout() {
            window.layoutIfNeeded()
            components.controller.view.layoutSubtreeIfNeeded()
        }

        private static func flexibleView() -> AnyView {
            AnyView(Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity))
        }
    }
}
