import AppKit
import Combine
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-308: the remote overview at the smallest detail pane, with a finished
/// Test Connection result, must not squeeze the grouped form's rows.
@MainActor
struct LeoMachinesSettingsLayoutTests {
    private struct SuccessTester: LeoMachineConnectionTesting {
        func test(_ configuration: LeoHostConfiguration) async -> LeoConnectionTestReport {
            .success(version: "0.57.0", statsAdvertised: true, duration: 1.11)
        }
    }

    private static let paneSize = NSSize(width: 590, height: 600)

    private static func mounted() async -> (NSWindow, NSView) {
        let defaults = LeoInMemoryDefaults()
        let store = LeoHostStore(defaults: defaults)
        try? store.save([.init(name: "work", sshTarget: "evan@work")])
        let model = LeoMachinesSettingsModel(store: store, tester: SuccessTester())
        await model.testSelected()
        let target = LeoSettingsTargetModel(
            clients: FakeMachineClients(), machines: { [.local] }, status: { _ in nil }, statuses: Empty().eraseToAnyPublisher(),
            reconnect: { _ in }, initialHost: nil
        )
        let view = LeoRemoteOverviewView(model: model, target: target, registry: LeoMachineRegistry.isolatedForTesting(defaults: defaults))
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: paneSize), styleMask: .borderless, backing: .buffered, defer: false
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

    private static func editableFields(in root: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        func visit(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable { found.append(field) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    @Test func theConnectionRowsKeepTheirHeightAtTheSmallestPaneWithATestResult() async throws {
        let (window, hosting) = await Self.mounted()
        defer { window.close() }
        let fields = Self.editableFields(in: hosting)

        #expect(fields.count >= 4, "the connection form's fields are on screen, got \(fields.count)")
        for field in fields {
            #expect(field.frame.height >= 16, "a field is squeezed to \(field.frame.height) pt")
            #expect(field.frame.width >= 100, "a field is squeezed to \(field.frame.width) pt wide")
        }
    }
}
