import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-440: dragging a Browser or Files tab over the terminal docks it through
/// the same `LeoPaneDockController.move` the menus use, and a drag that ends
/// anywhere else changes nothing.
@MainActor
struct LeoPaneDockDropTests {
    private let presence = FakePresence()
    private let defaults = LeoInMemoryDefaults()

    private func makeHarness(store: LeoPaneDockStore? = nil) -> LeoPaneDockTestHarness {
        LeoPaneDockTestHarness(presence: presence, store: store ?? LeoPaneDockStore(defaults: defaults))
    }

    /// A drag of `pane` at `point` (in the overlay's coordinates) from `source`.
    private func makeDrag(
        _ pane: LeoDockPane, at point: NSPoint, in overlay: LeoDockDropOverlay, from source: NSView?
    ) -> LeoDockDraggingInfo {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("studio.blackpaw.leo.test.\(UUID().uuidString)"))
        LeoDockPaneDrag.write(pane, to: pasteboard)
        return LeoDockDraggingInfo(pasteboard: pasteboard, source: source, window: overlay.window, location: overlay.convert(point, to: nil))
    }

    private func zonePoint(_ edge: LeoDockEdge, in overlay: LeoDockDropOverlay) -> NSPoint {
        let zone = LeoDockDropZone.frame(for: edge, in: overlay.bounds)
        return NSPoint(x: zone.midX, y: zone.midY)
    }

    /// Which container each slot hosts, by role, for comparing two windows.
    private func hosting(_ harness: LeoPaneDockTestHarness) -> [String] {
        let dock = harness.dock
        func name(_ slot: LeoDockSlotViewController?) -> String {
            switch slot?.hosted {
            case nil: "-"
            case dock.outline?: "outline"
            case dock.filesStrip?: "files"
            case dock.browserStrip?: "browser"
            default: "?"
            }
        }
        return [dock.rightOutline, dock.rightStrip, dock.belowOutline, dock.belowStrip].map(name)
    }

    @Test func overlayShowsOnlyDuringADrag() {
        let harness = makeHarness()
        defer { harness.close() }
        let overlay = harness.terminalDock.dropOverlay

        #expect(overlay.isHidden)
        harness.dock.beginDrag(.browser)
        #expect(!overlay.isHidden)
        harness.dock.endDrag()
        #expect(overlay.isHidden)
    }

    @Test func aDropInTheZoneDocksAsTheMenuDoes() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let harness = makeHarness()
            let reference = makeHarness(store: LeoPaneDockStore(defaults: LeoInMemoryDefaults()))
            defer {
                harness.close()
                reference.close()
            }
            try await harness.openFile(in: sandbox)
            try await reference.openFile(in: sandbox)
            presence.open(LeoAgentBrowserKey(host: .local, agent: "alpha"))
            await harness.settle()
            await reference.settle()
            let overlay = harness.terminalDock.dropOverlay

            for (pane, edge) in [(LeoDockPane.browser, LeoDockEdge.below), (.files, .below), (.files, .right)] {
                harness.dock.beginDrag(pane)
                let drag = makeDrag(pane, at: zonePoint(edge, in: overlay), in: overlay, from: harness.window.contentView)
                #expect(overlay.draggingEntered(drag) == .move)
                #expect(overlay.performDragOperation(drag))
                harness.dock.endDrag()
                reference.dock.move(pane, to: edge)
                await harness.settle()
                await reference.settle()

                #expect(harness.dock.store.layout == reference.dock.store.layout)
                #expect(hosting(harness) == hosting(reference))
                #expect(overlay.isHidden)
            }
            #expect(LeoPaneDockFocus.pane(for: harness.window.firstResponder) == LeoPaneDockFocus.pane(for: reference.window.firstResponder))
        }
    }

    @Test func aDropOutsideTheZoneLeavesTheLayoutUnchanged() {
        let harness = makeHarness()
        defer { harness.close() }
        let overlay = harness.terminalDock.dropOverlay
        let before = harness.dock.store.layout
        harness.dock.beginDrag(.browser)
        let topCentre = NSPoint(x: overlay.bounds.midX, y: overlay.bounds.maxY - 10)
        let drag = makeDrag(.browser, at: topCentre, in: overlay, from: harness.window.contentView)

        #expect(overlay.draggingEntered(drag) == [])
        #expect(!overlay.performDragOperation(drag))
        harness.dock.endDrag()

        #expect(harness.dock.store.layout == before)
        #expect(defaults.object(forKey: LeoPaneDockStore.Keys.edge(of: .browser)) == nil)
    }

    @Test func cancellingADragLeavesTheLayoutUnchanged() {
        let harness = makeHarness()
        defer { harness.close() }
        let overlay = harness.terminalDock.dropOverlay
        let before = harness.dock.store.layout
        harness.dock.beginDrag(.files)
        let drag = makeDrag(.files, at: zonePoint(.below, in: overlay), in: overlay, from: harness.window.contentView)
        _ = overlay.draggingEntered(drag)

        harness.dock.endDrag()

        #expect(harness.dock.store.layout == before)
        #expect(overlay.isHidden)
    }

    @Test func aDragFromAnotherWindowIsRefused() {
        let harness = makeHarness()
        let other = makeHarness(store: LeoPaneDockStore(defaults: LeoInMemoryDefaults()))
        defer {
            harness.close()
            other.close()
        }
        let overlay = harness.terminalDock.dropOverlay
        other.dock.beginDrag(.browser)
        #expect(overlay.isHidden, "only the dragging window shows its overlay")

        harness.dock.beginDrag(.browser)
        let drag = makeDrag(.browser, at: zonePoint(.below, in: overlay), in: overlay, from: other.window.contentView)

        #expect(overlay.draggingEntered(drag) == [])
        #expect(!overlay.performDragOperation(drag))
        #expect(harness.dock.store.layout == LeoPaneDockLayout())
    }
}

/// A dragging session's side of a drop, for driving an overlay without a real drag.
@MainActor
final class LeoDockDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    private let source: NSView?
    private let window: NSWindow?
    private let location: NSPoint

    init(pasteboard: NSPasteboard, source: NSView?, window: NSWindow?, location: NSPoint) {
        draggingPasteboard = pasteboard
        self.source = source
        self.window = window
        self.location = location
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
