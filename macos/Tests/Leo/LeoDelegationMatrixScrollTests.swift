import AppKit
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

/// A matrix wider than its pane opens with the active profile's column in view
/// and follows the active profile when it changes.
@MainActor struct LeoDelegationMatrixScrollTests {
    private static let paneWidth: CGFloat = 900
    private static let columnSpacing: CGFloat = 8

    private static func model() async throws -> LeoDelegationSettingsModel {
        let fake = try LeoConfigGolden.client(delegation: LeoDelegationFixtures.wide())
        let model = LeoDelegationSettingsModel(client: fake, revisions: LeoConfigRevisionTracker(), machineHost: "dionysus")
        await model.load()
        return model
    }

    /// Where profile `index`'s column sits in the grid, from the view's own widths.
    private static func column(_ index: Int) -> ClosedRange<CGFloat> {
        let step = LeoDelegationMatrixView.profileColumnWidth + columnSpacing
        let start = LeoDelegationMatrixView.roleColumnWidth + columnSpacing + CGFloat(index) * step
        return start...(start + LeoDelegationMatrixView.profileColumnWidth)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    private static func isVisible(_ range: ClosedRange<CGFloat>, in scroll: NSScrollView) -> Bool {
        let visible = scroll.contentView.bounds
        return range.lowerBound >= visible.minX && range.upperBound <= visible.maxX
    }

    /// Lets SwiftUI's appear/change work reach the scroll view without a wall-clock wait.
    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func host(_ model: LeoDelegationSettingsModel) -> (NSWindow, NSScrollView?) {
        let size = NSSize(width: Self.paneWidth, height: 900)
        let view = NSHostingView(rootView: LeoDelegationMatrixView(model: model, request: .constant(nil)).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return (window, Self.scrollView(in: view))
    }

    @Test func theActiveProfileColumnStartsInView() async throws {
        let model = try await Self.model()
        let activeIndex = try #require(model.matrix.profiles.firstIndex { $0.active })
        let (window, found) = host(model)
        defer { window.close() }
        let scroll = try #require(found)

        await Self.settle { Self.isVisible(Self.column(activeIndex), in: scroll) }

        #expect(Self.isVisible(Self.column(activeIndex), in: scroll))
    }

    @Test func theMatrixScrollsToANewActiveProfile() async throws {
        let model = try await Self.model()
        let (window, found) = host(model)
        defer { window.close() }
        let scroll = try #require(found)
        await Self.settle { scroll.contentView.bounds.minX > 0 }

        await model.requestActivate("thorough")
        await model.confirmActivate()
        let activeIndex = try #require(model.matrix.profiles.firstIndex { $0.active })
        await Self.settle { Self.isVisible(Self.column(activeIndex), in: scroll) }

        #expect(model.matrix.activeProfile?.name == "thorough")
        #expect(Self.isVisible(Self.column(activeIndex), in: scroll))
    }
}
