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
        var split: LeoSplitViewController?
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
                onPaneContainer: { [state] in state.split = $0.parent as? LeoSplitViewController },
                onSidebarAutoCollapse: { [state] in state.isVisible = false },
                onSidebarAutoRestore: { [state] in state.isVisible = true })
        }
    }

    /// Turns of the main queue, laying the window out after each, until
    /// `condition` holds. Gives up after a few seconds, which only a stuck
    /// condition reaches: callers `#require` what they waited for, so a miss
    /// fails there, not as a downstream symptom.
    private func settle(_ window: NSWindow, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, !condition() {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            window.layoutIfNeeded()
        }
    }

    /// What `makeRoom` needs before it will act: the split in a window, with a width.
    private func isSplitReady(_ state: SidebarState) -> Bool {
        guard let split = state.split else { return false }
        return split.view.window != nil && split.splitView.bounds.width > 0
    }

    private func layoutDescription(_ state: SidebarState) -> String {
        guard let split = state.split else { return "no split" }
        let panes = split.splitView.arrangedSubviews.map { $0.frame.width }
        return "split \(split.splitView.bounds.width), panes \(panes), collapsed \(split.splitViewItems.map(\.isCollapsed)), in window \(split.view.window != nil)"
    }

    /// D-058: showing the sidebar where it would squeeze the terminal
    /// leaves it collapsed, and the session hears it's still hidden.
    @Test func showingTheSidebarWhereItWouldSqueezeTheTerminalIsRefused() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let state = SidebarState()
        let editor = LeoEditorTabs(makeAccess: { _ in LeoFileAccessor.local() })
        let browser = LeoWorkspaceBrowserModel(makeAccess: { _ in LeoFileAccessor.local() }, openFile: { _ in .opened })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Host(state: state, editor: editor, browser: browser))
        window.setContentSize(NSSize(width: 1_000, height: 600))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle(window) { isSplitReady(state) }
        try #require(isSplitReady(state), "the split never reached the window: \(layoutDescription(state))")

        await browser.open(LeoEditorAgentContext(host: .local, name: "scratch", workspace: sandbox.root))
        try await editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.swift", "let a = 1")))
        await settle(window) { !state.isVisible }
        let sidebarItem = try #require(state.split?.sidebarItem)
        try #require(sidebarItem.isCollapsed, "opening both panes made room: \(layoutDescription(state))")
        try #require(state.split?.sidebarSqueezesTerminal(atWidth: LeoSidebarSplitMetrics.minimumWidth) == true)

        state.isVisible = true
        await settle(window) { !state.isVisible }

        #expect(!state.isVisible, "the session heard it is still hidden")
        #expect(sidebarItem.isCollapsed, "\(layoutDescription(state))")
        await editor.closeAll()
        await browser.close()
    }
}
