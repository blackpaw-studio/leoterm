import LeoKit
import SwiftUI

/// A chat bubble's outline: rounded corners, a tail on the sender's side at
/// the bottom for the last bubble of a group. The outline itself lives in
/// LeoKit so iOS draws the same one; the tail sits outside `rect`.
struct LeoChatBubbleShape: Shape {
    let side: LeoChatBubbleGeometry.Side
    let position: LeoChatTranscript.GroupPosition

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for element in LeoChatBubbleGeometry.outline(in: rect, side: side, position: position) {
            switch element {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .curve(let to, let c1, let c2): path.addCurve(to: to, control1: c1, control2: c2)
            case .corner(let t1, let t2, let radius): path.addArc(tangent1End: t1, tangent2End: t2, radius: radius)
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}
