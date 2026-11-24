import AppKit
import Combine
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// The sidebar toggled through SwiftUI, as ⌘⇧L does: the representable's
/// `updateNSViewController` is what shows it, so that's what's driven.
@MainActor struct LeoSplitViewRepresentableUpdateTests {
    @MainActor private final class SidebarState: ObservableObject {
        @Published var isVisible = true
        weak var container: LeoRowPaneContainerViewController?
        /// Found on use, as the window session does: up from a pane's container.
        var split: LeoSplitViewController? { container?.enclosingLeoSplit }
    }

    private struct Host: View {
        @ObservedObject var state: SidebarState
        let editor: LeoEditorTabs
        let browser: LeoWorkspaceBrowserModel

        var body: some View {
            LeoSplitViewRepresentable(
                isSidebarVisible: state.isVisible,
                preferredWidth: LeoSidebarSplitMetrics.minimumWidth,
                onDividerWidthChange: { _ in },
                sidebar: Color.clear,
                detail: Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity),
                editor: editor,
                browser: browser,
                onPaneContainer: { [state] in if $0.role == .editor { state.container = $0 } },
                onSidebarAutoCollapse: { [state] in state.isVisible = false },
                onSidebarAutoRestore: { [state] in state.isVisible = true })
        }
    }

    /// Turns of the main queue, laying the window out after each, until
    /// `condition` holds (or a few seconds pass).
    private func settle(_ window: NSWindow, until condition: () -> Bool = { false }) async {
        let deadline = ContinuousClock.now + .seconds(3)
        var turns = 0
        while ContinuousClock.now < deadline, turns < 10 || !condition() {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.layoutIfNeeded()
            turns += 1
            if turns >= 10, condition() { return }
        }
    }

    /// D-058: showing the sidebar where it would squeeze the terminal
    /// leaves it collapsed, and the session hears it's still hidden.
    @Test func showingTheSidebarWhereItWouldSqueezeTheTerminalIsRefused() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let state = SidebarState()
        let editor = LeoEditorTabs(makeAccess: { _ in LeoFileAccessor.local() })
        let browser = LeoWorkspaceBrowserModel(makeAccess: { _ in LeoFileAccessor.local() }, openFile: { _ in .opened })
        // 20 pt short of the sidebar, both panes at their minimums, and the terminal's floor.
        let width = LeoSidebarSplitMetrics.minimumWidth + LeoWorkspaceBrowserViewController.minimumWidth
            + LeoEditorPaneViewController.minimumWidth + LeoSidebarSplitMetrics.terminalFloor - 20
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Host(state: state, editor: editor, browser: browser))
        window.setContentSize(NSSize(width: width, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle(window)

        await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await settle(window) { !state.isVisible }
        let sidebarItem = try #require(state.split?.sidebarItem)
        try #require(sidebarItem.isCollapsed, "opening both panes made room")
        try #require(state.split?.sidebarSqueezesTerminal(atWidth: LeoSidebarSplitMetrics.minimumWidth) == true)

        state.isVisible = true
        await settle(window) { !state.isVisible }

        #expect(sidebarItem.isCollapsed)
        #expect(!state.isVisible)
        await editor.closeAll()
        await browser.close()
    }
}
