import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-308: the Machines detail pane at its minimum size, with a finished
/// Test Connection result, must not squeeze the grouped form.
@MainActor
struct LeoMachinesSettingsLayoutTests {
    private struct SuccessTester: LeoMachineConnectionTesting {
        func test(_ configuration: LeoHostConfiguration) async -> LeoConnectionTestReport {
            .success(version: "0.57.0", statsAdvertised: true, duration: 1.11)
        }
    }

    private static func mounted() async -> (NSWindow, NSView) {
        let defaults = LeoInMemoryDefaults()
        let store = LeoHostStore(defaults: defaults)
        try? store.save([.init(name: "work", sshTarget: "evan@work")])
        let model = LeoMachinesSettingsModel(store: store, tester: SuccessTester())
        await model.testSelected()
        let view = LeoMachinesSettingsView(
            model: model, statsStyle: LeoStatsStyleSetting(defaults: defaults), agentBrowser: LeoAgentBrowserSetting(defaults: defaults),
            registry: LeoMachineRegistry.isolatedForTesting(defaults: defaults)
        )
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 780, height: 600), styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderBack(nil)
        for _ in 0..<8 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            await Task.yield()
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    /// The grouped form's own scroll view: it holds the "Remote Socket Path" row.
    private static func formScrollView(in root: NSView) -> NSScrollView? {
        var found: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.documentView.map({ String(describing: type(of: $0)) == "DocumentView" }) == true,
                scroll.frame.width > 400
            {
                found = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    @Test func theFormShowsAllItsRowsAtTheMinimumWindowSizeWithATestResult() async throws {
        let (window, hosting) = await Self.mounted()
        defer { window.close() }
        let scroll = try #require(Self.formScrollView(in: hosting))
        let document = try #require(scroll.documentView)

        #expect(scroll.contentView.bounds.height >= document.frame.height, "the form is squeezed to \(scroll.contentView.bounds.height) of \(document.frame.height) pt")
    }
}
