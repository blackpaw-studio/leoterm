import AppKit
import Testing

@testable import Ghostty

/// B-440: the zone a dragged pane can land in.
struct LeoDockDropZoneTests {
    private let bounds = NSRect(x: 0, y: 0, width: 600, height: 400)

    @Test func offersOnlyTheEdgeThePaneIsNotOn() {
        let layout = LeoPaneDockLayout().moving(.files, to: .below)

        #expect(LeoDockDropZone.target(for: .browser, layout: layout) == .below)
        #expect(LeoDockDropZone.target(for: .files, layout: layout) == .right)
    }

    @Test(arguments: LeoDockEdge.allCases)
    func zoneIsTheTerminalsHalfAlongThatEdge(edge: LeoDockEdge) {
        let zone = LeoDockDropZone.frame(for: edge, in: bounds)

        #expect(bounds.contains(zone.origin) && zone.maxX <= bounds.maxX && zone.maxY <= bounds.maxY)
        switch edge {
        case .right:
            #expect(zone.maxX == bounds.maxX && zone.height == bounds.height)
            #expect(zone.width == bounds.width * LeoDockDropZone.zoneFraction)
        case .below:
            #expect(zone.minY == bounds.minY && zone.width == bounds.width)
            #expect(zone.height == bounds.height * LeoDockDropZone.zoneFraction)
        }
    }

    @Test func aPointOutsideTheZoneIsNoDrop() {
        let topCentre = NSPoint(x: 300, y: 390)
        let leftEdge = NSPoint(x: 5, y: 300)
        let leftHalf = NSPoint(x: 100, y: 100)

        #expect(!LeoDockDropZone.contains(topCentre, edge: .below, in: bounds))
        #expect(!LeoDockDropZone.contains(leftEdge, edge: .below, in: bounds))
        #expect(!LeoDockDropZone.contains(leftHalf, edge: .right, in: bounds))
        #expect(LeoDockDropZone.contains(NSPoint(x: 300, y: 100), edge: .below, in: bounds))
        #expect(LeoDockDropZone.contains(NSPoint(x: 500, y: 390), edge: .right, in: bounds))
    }
}
