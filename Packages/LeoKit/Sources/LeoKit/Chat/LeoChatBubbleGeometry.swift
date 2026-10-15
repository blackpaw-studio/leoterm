import CoreGraphics
import Foundation

/// The shape of an iMessage-style chat bubble as plain path elements, so the
/// Mac (SwiftUI `Path`) and iOS (`CGMutablePath`) draw identical outlines.
/// Coordinates are y-down, as on screen.
public enum LeoChatBubbleGeometry {
    /// Which edge the sender's side (and tail) is on.
    public enum Side: Equatable, Sendable { case leading, trailing }

    public enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(to: CGPoint, c1: CGPoint, c2: CGPoint)
        /// A rounded corner: `CGPath.addArc(tangent1End:tangent2End:radius:)`.
        case corner(tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat)
        case close
    }

    public static let cornerRadius: CGFloat = 17
    public static let groupedCornerRadius: CGFloat = 5
    /// How far the tail tip sticks out past the body.
    public static let tailWidth: CGFloat = 4
    /// How far in from the body edge the tail starts along the bottom.
    public static let tailBaseInset: CGFloat = 13
    /// How far up the side edge the tail climbs.
    public static let tailRise: CGFloat = 11

    /// The outline of a bubble body in `rect`; a tail extends `tailWidth`
    /// beyond `rect` on the sender's side. Wound from the bottom edge, up the
    /// sender's side, over the top and down the other side.
    public static func outline(in rect: CGRect, side: Side, position: LeoChatTranscript.GroupPosition) -> [Element] {
        let trailing = trailingOutline(in: rect, position: position)
        return side == .trailing ? trailing : trailing.map { $0.mirrored(aboutX: rect.midX) }
    }

    private static func trailingOutline(in rect: CGRect, position: LeoChatTranscript.GroupPosition) -> [Element] {
        let limit = min(rect.height, rect.width) / 2
        let outer = min(cornerRadius, limit)
        let grouped = min(groupedCornerRadius, limit)
        let hasTail = position == .single || position == .last
        let senderTop = [.single, .first].contains(position) ? outer : grouped
        let tailTop = hasTail ? min(senderTop, rect.height - tailRise) : senderTop
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)

        let bottomRight: [Element] =
            hasTail
            ? tail(maxX: maxX, maxY: maxY, baseX: max(maxX - tailBaseInset, minX + outer))
            : [
                .line(CGPoint(x: maxX - grouped, y: maxY)),
                .corner(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - grouped), radius: grouped),
            ]
        return [.move(CGPoint(x: minX + outer, y: maxY))] + bottomRight + [
            .line(CGPoint(x: maxX, y: minY + tailTop)),
            .corner(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX - tailTop, y: minY), radius: tailTop),
            .line(CGPoint(x: minX + outer, y: minY)),
            .corner(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX, y: minY + outer), radius: outer),
            .line(CGPoint(x: minX, y: maxY - outer)),
            .corner(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + outer, y: maxY), radius: outer),
            .close,
        ]
    }

    private static func tail(maxX: CGFloat, maxY: CGFloat, baseX: CGFloat) -> [Element] {
        [
            .line(CGPoint(x: baseX, y: maxY)),
            .curve(
                to: CGPoint(x: maxX + tailWidth, y: maxY), c1: CGPoint(x: maxX - 3.6, y: maxY), c2: CGPoint(x: maxX - 0.1, y: maxY - 2)
            ),
            .curve(
                to: CGPoint(x: maxX, y: maxY - tailRise), c1: CGPoint(x: maxX - 0.7, y: maxY - 1.3),
                c2: CGPoint(x: maxX, y: maxY - 4.7)
            ),
        ]
    }
}

extension LeoChatBubbleGeometry.Element {
    fileprivate func mirrored(aboutX midX: CGFloat) -> Self {
        func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: 2 * midX - point.x, y: point.y) }
        switch self {
        case .move(let point): return .move(flip(point))
        case .line(let point): return .line(flip(point))
        case .curve(let to, let c1, let c2): return .curve(to: flip(to), c1: flip(c1), c2: flip(c2))
        case .corner(let t1, let t2, let radius): return .corner(tangent1End: flip(t1), tangent2End: flip(t2), radius: radius)
        case .close: return .close
        }
    }
}

extension LeoChatTranscript {
    public static let groupedSpacing: CGFloat = 2
    public static let groupSpacing: CGFloat = 10
    public static let headerSpacing: CGFloat = 16
    /// An ask under the task card it follows up.
    public static let taskFollowUpSpacing: CGFloat = 4

    /// The gap above `item`, given the item shown just before it.
    public static func spacing(above item: Item, after previous: Item?) -> CGFloat {
        guard let previous else { return 0 }
        guard case .message(let message, let position) = item, case .message(let before, _) = previous else { return headerSpacing }
        if position == .middle || position == .last { return groupedSpacing }
        if before.kind == .task, message.continuesPost(after: before) { return taskFollowUpSpacing }
        return groupSpacing
    }
}
