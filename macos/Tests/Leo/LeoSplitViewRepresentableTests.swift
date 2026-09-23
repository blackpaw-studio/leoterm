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
        let sidebar = LeoSidebarSplitMetrics.sidebarHoldingPriority
        #expect(terminal < editor && editor < sidebar)
        // NSSplitView's low band: higher freezes the pane (see LeoSidebarSplitMetrics).
        #expect(editor.rawValue >= 250 && editor.rawValue <= 260)
    }

    private static func makeEditor() -> LeoEditorPaneModel {
        LeoEditorPaneModel(makeAccess: { _ in LeoFileAccessor.local() })
    }

    /// A live split view controller inside a real, correctly sized window.
    @MainActor private final class Harness {
        let components: (controller: LeoSplitViewController,
                         sidebarHosting: NSHostingController<AnyView>,
                         detailHosting: NSHostingController<AnyView>)
        let window: NSWindow

        init(preferredWidth: CGFloat = 240, editor: LeoEditorPaneModel? = nil) {
            components = LeoSplitViewControllerFactory.make(
                isSidebarVisible: true,
                preferredWidth: preferredWidth,
                onDividerWidthChange: { _ in },
                sidebar: Self.flexibleView(),
                detail: Self.flexibleView(),
                editor: editor)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: LeoSplitViewRepresentableTests.windowWidth, height: LeoSplitViewRepresentableTests.windowHeight),
                styleMask: [.titled],
                backing: .buffered,
                defer: false)
            window.contentViewController = components.controller
            // Assigning `contentViewController` shrinks the window to that
            // controller's fitting size, which would leave the split view far
            // too narrow for the divider to have anywhere to travel.
            window.setContentSize(NSSize(width: LeoSplitViewRepresentableTests.windowWidth, height: LeoSplitViewRepresentableTests.windowHeight))
            window.makeKeyAndOrderFront(nil)
            layout()
        }

        var sidebarWidth: CGFloat { components.sidebarHosting.view.frame.width }

        var editorItem: NSSplitViewItem? {
            components.controller.splitViewItems.first { $0.viewController is LeoEditorPaneViewController }
        }

        var editorWidth: CGFloat { editorItem?.viewController.view.frame.width ?? 0 }

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
