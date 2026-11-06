import AppKit
import Combine
import Sparkle
import SwiftUI
import Testing

@testable import Ghostty

/// The capsule's toolbar item is always present, with width, and takes the
/// click: AppKit hit-tests the view's bounds, and SwiftUI content drawn
/// outside a zero-width hosting view is visible but dead.
@MainActor
struct LeoAgentToolbarActivityTests {
    private final class CapsuleStandIn: NSView {}

    /// The update pill's size: its intrinsic size is what the toolbar lays out.
    private final class PillStandIn: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 22) }
    }

    private struct Fixture {
        let window: NSWindow
        let toolbar: LeoAgentToolbar
        let capsule: CapsuleStandIn
        let pill: PillStandIn
        let chatWidth = PassthroughSubject<CGFloat, Never>()
        let updateVisible = PassthroughSubject<Bool, Never>()

        var identifiers: [NSToolbarItem.Identifier] { window.toolbar?.items.map(\.itemIdentifier) ?? [] }
        var updateItem: NSToolbarItem? { window.toolbar?.items.first { $0.itemIdentifier == .leoUpdate } }
        func windowFrame(of view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

        var item: NSToolbarItem? { window.toolbar?.items.first { $0.itemIdentifier == .leoActivity } }
        var itemView: NSView? { item?.view }

        /// What a click at the capsule item's center reaches.
        var hitAtCenter: NSView? {
            guard let view = itemView else { return nil }
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            return window.contentView?.superview?.hitTest(center)
        }

        /// Waits (short polls, never a fixed sleep) until the toolbar's items stop moving.
        func settle() async {
            window.layoutIfNeeded()
            let deadline = ContinuousClock.now + .seconds(2)
            func snapshot() -> [NSRect] {
                [itemView, updateItem?.view].compactMap { $0.map(windowFrame(of:)) } + [NSRect(x: identifiers.count, y: 0, width: 0, height: 0)]
            }
            var last = snapshot()
            var stable = 0
            while ContinuousClock.now < deadline, stable < 3 {
                try? await Task.sleep(for: .milliseconds(10))
                window.layoutIfNeeded()
                let now = snapshot()
                stable = now == last ? stable + 1 : 0
                last = now
            }
        }
    }

    private static func makeFixture(hidesItemsInPlace: Bool? = nil, updateView: NSView? = nil) -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        // close() must not over-release: ARC owns the window, and the default
        // (true) crashes the host at the next autorelease-pool drain.
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 600))
        let capsule = CapsuleStandIn()
        let pill = PillStandIn()
        let toolbar = LeoAgentToolbar()
        toolbar.makeActivityView = { capsule }
        toolbar.makeUpdateView = { updateView ?? pill }
        if let hidesItemsInPlace { toolbar.hidesItemsInPlace = hidesItemsInPlace }
        toolbar.install(on: window)
        let fixture = Fixture(window: window, toolbar: toolbar, capsule: capsule, pill: pill)
        toolbar.bind(sideBySideChatWidth: fixture.chatWidth)
        toolbar.bind(updateVisible: fixture.updateVisible)
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

    // MARK: The update pill (B-349)

    @Test func thePillSitsInTheToolbarRowJustBeforeTheMoreItem() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.window.orderFrontRegardless()
        fixture.window.setContentSize(NSSize(width: 1200, height: 600))
        fixture.updateVisible.send(true)
        await fixture.settle()
        let item = try #require(fixture.updateItem, "no update item: \(fixture.identifiers)")
        let container = try #require(fixture.itemView, "the toolbar never built the capsule item")

        let ids = fixture.identifiers
        #expect(ids.firstIndex(of: .leoUpdate) == ids.firstIndex(of: .leoMore).map { $0 - 1 }, "\(ids.map(\.rawValue))")
        #expect(!item.isHidden)
        let pill = fixture.windowFrame(of: fixture.pill)
        let capsule = fixture.windowFrame(of: container)
        #expect(pill.width > 0)
        #expect(abs(pill.midY - capsule.midY) <= 1, "pill \(pill) capsule \(capsule)")
        #expect(pill.minX >= capsule.maxX, "pill \(pill) capsule \(capsule)")
        #expect(pill.maxX <= fixture.window.frame.width, "pill \(pill)")
    }

    @Test func thePillIsHiddenWhileThereIsNoUpdate() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.window.orderFrontRegardless()
        fixture.window.setContentSize(NSSize(width: 1200, height: 600))
        fixture.updateVisible.send(true)
        await fixture.settle()
        fixture.updateVisible.send(false)
        await fixture.settle()

        #expect(fixture.updateItem?.isHidden ?? true)
    }

    @Test func thePillGivesWayWhenTheToolbarHasNoRoomForIt() async throws {
        let fixture = Self.makeFixture()
        defer { fixture.window.close() }
        fixture.window.orderFrontRegardless()
        fixture.window.setContentSize(NSSize(width: 520, height: 600))
        fixture.updateVisible.send(true)
        await fixture.settle()

        #expect(fixture.updateItem?.isHidden ?? true)
    }

    /// Below macOS 15 `isHidden` does nothing: the item is inserted right
    /// before "⋯" and removed again, never left as a ghost.
    @Test func withoutItemHidingThePillIsInsertedBeforeTheMoreItemAndRemoved() async throws {
        let fixture = Self.makeFixture(hidesItemsInPlace: false)
        defer { fixture.window.close() }
        fixture.window.orderFrontRegardless()
        fixture.window.setContentSize(NSSize(width: 1200, height: 600))
        await fixture.settle()
        #expect(!fixture.identifiers.contains(.leoUpdate), "\(fixture.identifiers.map(\.rawValue))")

        fixture.updateVisible.send(true)
        await fixture.settle()
        let shown = fixture.identifiers
        #expect(shown.firstIndex(of: .leoUpdate) == shown.firstIndex(of: .leoMore).map { $0 - 1 }, "\(shown.map(\.rawValue))")

        fixture.updateVisible.send(false)
        await fixture.settle()
        #expect(!fixture.identifiers.contains(.leoUpdate), "\(fixture.identifiers.map(\.rawValue))")
    }

    /// The real pill is a SwiftUI hosting view sized by its content: once an
    /// update state shows, the toolbar gives it its width.
    @Test func theRealPillGetsItsWidthOnceAnUpdateStateShows() async throws {
        let model = UpdateViewModel()
        let host = NonDraggableHostingView(rootView: UpdatePill(model: model))
        let fixture = Self.makeFixture(updateView: host)
        defer { fixture.window.close() }
        fixture.window.orderFrontRegardless()
        fixture.window.setContentSize(NSSize(width: 1200, height: 600))
        await fixture.settle()

        model.state = .updateAvailable(.init(appcastItem: SUAppcastItem.empty(), reply: { _ in }))
        fixture.updateVisible.send(true)
        await fixture.settle()

        let frame = fixture.windowFrame(of: host)
        #expect(frame.width > 60 && frame.height > 10, "the pill was never given room: \(frame)")
        #expect(!(fixture.updateItem?.isHidden ?? true))
    }
}
