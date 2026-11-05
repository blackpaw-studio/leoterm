import AppKit
import Combine
import Testing

@testable import Ghostty

/// The capsule's toolbar item is always present, with width, and takes the
/// click: AppKit hit-tests the view's bounds, and SwiftUI content drawn
/// outside a zero-width hosting view is visible but dead.
@MainActor
struct LeoAgentToolbarActivityTests {
    private final class CapsuleStandIn: NSView {}

    private struct Fixture {
        let window: NSWindow
        let toolbar: LeoAgentToolbar
        let capsule: CapsuleStandIn
        let chatWidth = PassthroughSubject<CGFloat, Never>()

        var item: NSToolbarItem? { window.toolbar?.items.first { $0.itemIdentifier == .leoActivity } }
        var itemView: NSView? { item?.view }

        /// What a click at the capsule item's center reaches.
        var hitAtCenter: NSView? {
            guard let view = itemView else { return nil }
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            return window.contentView?.superview?.hitTest(center)
        }

        func settle() async {
            window.layoutIfNeeded()
            let deadline = ContinuousClock.now + .seconds(2)
            var lastWidth = itemView?.frame.width
            var stable = 0
            while ContinuousClock.now < deadline, stable < 3 {
                try? await Task.sleep(for: .milliseconds(10))
                window.layoutIfNeeded()
                let width = itemView?.frame.width
                stable = width == lastWidth ? stable + 1 : 0
                lastWidth = width
            }
        }
    }

    private static func makeFixture() -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        // close() must not over-release: ARC owns the window, and the default
        // (true) crashes the host at the next autorelease-pool drain.
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        let capsule = CapsuleStandIn()
        let toolbar = LeoAgentToolbar()
        toolbar.makeActivityView = { capsule }
        toolbar.install(on: window)
        let fixture = Fixture(window: window, toolbar: toolbar, capsule: capsule)
        toolbar.bind(sideBySideChatWidth: fixture.chatWidth)
        return fixture
    }

    @Test func theCapsuleHasWidthAndTakesTheClickBeforeAnyTaskArrives() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.window.orderFrontRegardless()
        fixture.window.setContentSize(NSSize(width: 1000, height: 600))
        await fixture.settle()
        try #require(fixture.itemView === fixture.capsule.superview, "the toolbar never built the capsule item")

        #expect(fixture.capsule.frame.width > 0, "\(fixture.capsule.frame)")
        let hit = try #require(fixture.hitAtCenter, "nothing at the capsule's center")
        #expect(hit === fixture.capsule || hit.isDescendant(of: fixture.capsule), "\(hit)")
    }

    @Test func chatBesideTheTerminalMovesTheCapsuleLeftAndClosingItPutsItBack() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.window.orderFrontRegardless()
        fixture.window.setContentSize(NSSize(width: 1400, height: 600))
        await fixture.settle()
        let container = try #require(fixture.itemView, "the toolbar never built the capsule item")

        fixture.chatWidth.send(448)
        await fixture.settle()

        // The capsule leads a container padded on its right: AppKit centres
        // the container, so the capsule's own centre moves left.
        #expect(container.frame.width > fixture.capsule.frame.width, "\(container.frame) \(fixture.capsule.frame)")

        fixture.chatWidth.send(0)
        await fixture.settle()

        #expect(container.frame.width == fixture.capsule.frame.width, "\(container.frame) \(fixture.capsule.frame)")
    }
}
