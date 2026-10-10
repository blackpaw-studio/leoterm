import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-273: the editor pane's tabs on screen. A background open shows the
/// pane without taking focus from the terminal; focus in the pane follows
/// the selected tab; the strip shows only with two or more tabs.
@MainActor
struct LeoEditorTabsViewControllerTests {
    /// Takes focus as a terminal does.
    private final class TerminalStandIn: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct StandIn: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    @MainActor private final class Harness {
        let tabs = LeoEditorTabs(makeAccess: { _ in LeoFileAccessor.local() })
        let terminal = TerminalStandIn()
        let split: LeoSplitViewController
        let window: NSWindow

        init() {
            split = LeoSplitViewControllerFactory.make(
                isSidebarVisible: false, preferredWidth: 240, onDividerWidthChange: { _ in },
                sidebar: AnyView(Color.clear), detail: AnyView(StandIn(view: terminal).frame(maxWidth: .infinity, maxHeight: .infinity)),
                editor: tabs
            ).controller
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = split
            window.setContentSize(NSSize(width: 1_400, height: 700))
            window.contentView?.layoutSubtreeIfNeeded()
        }

        var editorItem: NSSplitViewItem? { split.splitViewItems.first { $0.leoPaneRole == .editor } }
        var tabsView: LeoEditorTabsViewController? {
            (editorItem?.viewController as? LeoRowPaneContainerViewController)?.activeChild as? LeoEditorTabsViewController
        }

        var focusIsInTerminal: Bool { window.firstResponder === terminal }

        func isFocused(on tab: LeoEditorPaneModel) -> Bool {
            guard let view = tabsView?.view(for: tab) else { return false }
            return window.firstResponder === view.textView
        }

        func close() async {
            await tabs.release()
            window.close()
        }
    }

    private func file(_ sandbox: LeoFileSandbox, _ name: String) throws -> LeoEditorFileID {
        LeoEditorFileID(host: .local, path: try sandbox.file(name, name))
    }

    @Test
    func backgroundOpenKeepsFirstResponder() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = Harness()
            #expect(harness.window.makeFirstResponder(harness.terminal))

            try await harness.tabs.open(try file(sandbox, "a.txt"), line: 1, mode: .background)
            try await harness.tabs.open(try file(sandbox, "b.txt"), mode: .background)

            #expect(await eventually { harness.editorItem?.isCollapsed == false })
            #expect(await eventually { harness.tabsView?.shown?.model === harness.tabs.selected })
            await settle()
            #expect(harness.focusIsInTerminal)
            await harness.close()
        }
    }

    @Test
    func userOpenFocusesTheNewTab() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = Harness()
            #expect(harness.window.makeFirstResponder(harness.terminal))

            try await harness.tabs.open(try file(sandbox, "a.txt"))

            let tab = try #require(harness.tabs.selected)
            #expect(await eventually { harness.isFocused(on: tab) })
            await harness.close()
        }
    }

    @Test
    func focusInPaneMovesToNewSelectedTab() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = Harness()
            try await harness.tabs.open(try file(sandbox, "a.txt"))
            try await harness.tabs.open(try file(sandbox, "b.txt"))
            let (a, b) = (harness.tabs.tabs[0], harness.tabs.tabs[1])
            #expect(await eventually { harness.isFocused(on: b) })

            harness.tabs.selectPrevious()
            #expect(await eventually { harness.isFocused(on: a) })

            // Focus in the terminal stays there.
            #expect(harness.window.makeFirstResponder(harness.terminal))
            harness.tabs.selectNext()
            #expect(await eventually { harness.tabsView?.shown?.model === b })
            await settle()
            #expect(harness.focusIsInTerminal)
            await harness.close()
        }
    }

    @Test
    func closingTheFocusedTabFocusesItsNeighbour() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = Harness()
            try await harness.tabs.open(try file(sandbox, "a.txt"))
            try await harness.tabs.open(try file(sandbox, "b.txt"))
            let (a, b) = (harness.tabs.tabs[0], harness.tabs.tabs[1])
            #expect(await eventually { harness.isFocused(on: b) })

            #expect(await harness.tabs.closeTab(b))

            #expect(await eventually { harness.isFocused(on: a) })
            await harness.close()
        }
    }

    @Test
    func stripHiddenUnderTwoTabs() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = Harness()
            try await harness.tabs.open(try file(sandbox, "a.txt"))
            #expect(await eventually { harness.tabsView?.shown != nil })
            await settle()
            let bar = try #require(harness.tabsView?.tabBar)
            #expect(bar.isHidden)

            try await harness.tabs.open(try file(sandbox, "b.txt"))
            #expect(await eventually { !bar.isHidden })
            #expect(bar.items.map(\.title) == ["a.txt", "b.txt"])
            #expect(bar.items.map(\.isSelected) == [false, true])
            #expect(bar.isDescendant(of: try #require(harness.tabsView?.shown?.view)))

            harness.tabs.tabs[0].document?.edit("edited")
            #expect(await eventually { bar.items.first?.isDirty == true })

            harness.tabs.tabs[0].document?.edit("a.txt")
            #expect(await harness.tabs.closeSelected())
            #expect(await eventually { bar.isHidden })
            await harness.close()
        }
    }

    @Test
    func closingTheLastTabCollapsesThePane() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = Harness()
            try await harness.tabs.open(try file(sandbox, "a.txt"))
            #expect(await eventually { harness.editorItem?.isCollapsed == false })

            #expect(await harness.tabs.closeAll())

            #expect(await eventually { harness.editorItem?.isCollapsed == true })
            await harness.close()
        }
    }

    private func settle() async {
        for _ in 0 ..< 3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        return condition()
    }
}
