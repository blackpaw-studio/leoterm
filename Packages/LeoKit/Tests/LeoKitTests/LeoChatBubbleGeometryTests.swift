import CoreGraphics
import Foundation
import Testing

@testable import LeoKit

struct LeoChatBubbleGeometryTests {
    typealias Geometry = LeoChatBubbleGeometry
    static let rect = CGRect(x: 0, y: 0, width: 200, height: 40)

    static func points(_ elements: [Geometry.Element]) -> [CGPoint] {
        elements.flatMap { element -> [CGPoint] in
            switch element {
            case .move(let point), .line(let point): [point]
            case .curve(let to, let c1, let c2): [to, c1, c2]
            case .corner(let t1, let t2, _): [t1, t2]
            case .close: []
            }
        }
    }

    static func radii(_ elements: [Geometry.Element]) -> [CGFloat] {
        elements.compactMap { if case .corner(_, _, let radius) = $0 { radius } else { nil } }
    }

    static func curves(_ elements: [Geometry.Element]) -> [[CGPoint]] {
        elements.compactMap { if case .curve(let to, let c1, let c2) = $0 { [to, c1, c2] } else { nil } }
    }

    @Test func aTrailingLastBubbleHasItsTailTipFourPointsOutside() {
        let curves = Self.curves(Geometry.outline(in: Self.rect, side: .trailing, position: .last))
        #expect(curves == [
            [CGPoint(x: 204, y: 40), CGPoint(x: 196.4, y: 40), CGPoint(x: 199.9, y: 38)],
            [CGPoint(x: 200, y: 29), CGPoint(x: 199.3, y: 38.7), CGPoint(x: 200, y: 35.3)],
        ])
    }

    @Test func aLeadingSingleBubbleMirrorsTheTail() {
        let curves = Self.curves(Geometry.outline(in: Self.rect, side: .leading, position: .single))
        #expect(curves.first?.first == CGPoint(x: -4, y: 40))
        #expect(curves.last?.first == CGPoint(x: 0, y: 29))
    }

    @Test(arguments: [LeoChatTranscript.GroupPosition.first, .middle])
    func groupedBubblesStayInsideTheirRect(position: LeoChatTranscript.GroupPosition) {
        for side in [Geometry.Side.leading, .trailing] {
            let points = Self.points(Geometry.outline(in: Self.rect, side: side, position: position))
            #expect(points.allSatisfy { (0...200).contains($0.x) && (0...40).contains($0.y) })
        }
    }

    @Test func aMiddleBubbleRoundsItsSenderCornersTightly() {
        // Order: sender-bottom, sender-top, other-top, other-bottom.
        #expect(Self.radii(Geometry.outline(in: Self.rect, side: .trailing, position: .middle)) == [5, 5, 17, 17])
        #expect(Self.radii(Geometry.outline(in: Self.rect, side: .leading, position: .middle)) == [5, 5, 17, 17])
    }

    @Test func positionsPickTheSenderCornerRadii() {
        func radii(_ position: LeoChatTranscript.GroupPosition) -> [CGFloat] {
            Self.radii(Geometry.outline(in: Self.rect, side: .trailing, position: position))
        }
        #expect(radii(.single) == [17, 17, 17])
        #expect(radii(.first) == [5, 17, 17, 17])
        #expect(radii(.last) == [5, 17, 17])
    }

    @Test func aShortBubbleClampsItsRadiusToHalfItsHeight() {
        let short = CGRect(x: 0, y: 0, width: 200, height: 30)
        #expect(Self.radii(Geometry.outline(in: short, side: .trailing, position: .first)) == [5, 15, 15, 15])
    }

    @Test func theTailLeavesRoomForItsRise() {
        let short = CGRect(x: 0, y: 0, width: 200, height: 20)
        let radii = Self.radii(Geometry.outline(in: short, side: .trailing, position: .single))
        #expect(radii == [9, 10, 10])
    }

    @Test func spacingFollowsTheTranscriptRhythm() {
        func message(_ id: String, _ kind: LeoChatMessage.Kind = .text, task: String? = nil) -> LeoChatMessage {
            LeoChatMessage(id: id, agent: "zeus", direction: .outbound, kind: kind, text: id, task: task, ts: .distantPast)
        }
        typealias Item = LeoChatTranscript.Item
        let header = Item.timeHeader(.distantPast, id: "time-a")
        let single = Item.message(message("a"), position: .single)
        let last = Item.message(message("b"), position: .last)
        let task = Item.message(message("t", .task, task: "nightly"), position: .single)
        let ask = Item.message(message("q", .ask, task: "nightly"), position: .single)

        #expect(LeoChatTranscript.spacing(above: header, after: nil) == 0)
        #expect(LeoChatTranscript.spacing(above: single, after: header) == 16)
        #expect(LeoChatTranscript.spacing(above: header, after: single) == 16)
        #expect(LeoChatTranscript.spacing(above: last, after: single) == 2)
        #expect(LeoChatTranscript.spacing(above: ask, after: task) == 4)
        #expect(LeoChatTranscript.spacing(above: single, after: last) == 10)
    }
}
