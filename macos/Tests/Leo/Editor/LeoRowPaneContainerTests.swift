import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-274: the window's editor and browser split items show the pane of the
/// row on screen. Each row keeps its own views, so a switch back finds the
/// text, selection, scroll and undo as they were left.
@MainActor
struct LeoRowPaneContainerTests {
    private static let agentA = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "alpha"))
    private static let agentB = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "beta"))

    @MainActor private final class Harness {
        let panes: LeoRowPanes
        let split: LeoSplitViewController
        let window: NSWindow

        init() {
            panes = LeoRowPanes(makeAccess: { _ in LeoFileAccessor.local() }, confirm: { _, _ in .discard })
            split = LeoSplitViewControllerFactory.make(
                isSidebarVisible: false, preferredWidth: 240, onDividerWidthChange: { _ in },
                sidebar: AnyView(Color.clear), detail: AnyView(Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)),
                panes: panes
            ).controller
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = split
            window.setContentSize(NSSize(width: 1_400, height: 700))
            layout()
        }

        var editorItem: NSSplitViewItem { split.splitViewItems[3] }
        var editorPane: LeoEditorPaneViewController? {
            (editorItem.viewController as? LeoRowPaneContainerViewController)?.activeChild as? LeoEditorPaneViewController
        }

        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        func open(_ path: String, in key: LeoRowKey) async throws {
            panes.activate(key)
            try await panes.active.editor.open(LeoEditorFileID(host: .local, path: path))
            #expect(await eventually { !self.editorItem.isCollapsed })
            layout()
        }

        func close() async {
            await panes.releaseAll()
            window.close()
        }
    }

    @Test
    func switchingRowsKeepsSelectionScrollAndUndo() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let long = (1...400).map { "line \($0)" }.joined(separator: "\n")
            let harness = Harness()
            try await harness.open(try sandbox.file("a.txt", long), in: Self.agentA)
            let paneA = try #require(harness.editorPane)
            #expect(harness.editorItem.leoPaneRole == .editor)
            paneA.textView.setSelectedRange(NSRange(location: 2_000, length: 5))
            paneA.textView.scrollRangeToVisible(paneA.textView.selectedRange())
            paneA.textView.insertText("typed", replacementRange: paneA.textView.selectedRange())
            let scroll = paneA.textView.visibleRect.origin.y
            let selection = paneA.textView.selectedRange()
            #expect(scroll > 0)

            try await harness.open(try sandbox.file("b.txt", "b"), in: Self.agentB)
            #expect(harness.editorPane !== paneA)
            #expect(paneA.view.window == nil, "A's pane is off screen")

            harness.panes.activate(Self.agentA)
            harness.layout()

            #expect(harness.editorPane === paneA)
            #expect(paneA.view.window === harness.window)
            #expect(paneA.textView.selectedRange() == selection)
            #expect(abs(paneA.textView.visibleRect.origin.y - scroll) <= 1)
            #expect(paneA.textView.undoManager?.canUndo == true)
            #expect(harness.panes.active.editor.document?.isDirty == true)
            await harness.close()
        }
    }

    @Test
    func editorItemCollapsesForARowWithoutAFileAndReturns() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = Harness()
            try await harness.open(try sandbox.file("a.txt", "a"), in: Self.agentA)
            let width = harness.editorItem.viewController.view.frame.width

            harness.panes.activate(Self.agentB)
            #expect(harness.editorItem.isCollapsed)

            harness.panes.activate(Self.agentA)
            harness.layout()
            #expect(!harness.editorItem.isCollapsed)
            #expect(abs(harness.editorItem.viewController.view.frame.width - width) <= 1, "it comes back as wide as it was")
            await harness.close()
        }
    }

    @Test
    func aHiddenRowsCloseDoesNotCollapseTheShownPane() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = Harness()
            try await harness.open(try sandbox.file("b.txt", "b"), in: Self.agentB)
            try await harness.open(try sandbox.file("a.txt", "a"), in: Self.agentA)

            #expect(await harness.panes.close(Self.agentB))
            for _ in 0..<5 { await Task.yield() }

            #expect(!harness.editorItem.isCollapsed)
            await harness.close()
        }
    }

    @Test
    func showingARowChecksItsDocumentOnDisk() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let harness = Harness()
            try await harness.open(path, in: Self.agentA)
            let document = try #require(harness.panes.active.editor.document)
            harness.panes.activate(Self.agentB)
            try sandbox.file("a.txt", "changed elsewhere")

            harness.panes.activate(Self.agentA)

            #expect(await eventually { document.text == "changed elsewhere" })
            await harness.close()
        }
    }
}

@MainActor private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
