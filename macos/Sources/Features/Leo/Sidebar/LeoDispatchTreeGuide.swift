import SwiftUI

/// Which tree-guide verticals a dispatch row draws.
enum LeoDispatchGuides {
    /// For each node (given by its depth, depth first), one flag per level
    /// `0...depth`: whether that level's line carries on below this row. The
    /// last flag is the row's own sibling line (an elbow when false, a tee
    /// when true); the earlier ones are its ancestors' through-lines. A line
    /// continues when a later node sits at that level before the tree
    /// returns to a shallower one.
    static func continuing(depths: [Int]) -> [[Bool]] {
        depths.enumerated().map { index, depth in
            (0...max(depth, 0)).map { level in
                for later in depths[(index + 1)...] {
                    if later < level { return false }
                    if later == level { return true }
                }
                return false
            }
        }
    }
}

/// The guide drawn in a dispatch row's leading inset: rounded elbow into the
/// row, a through-line where siblings continue. Rows are drawn edge to edge
/// vertically so the lines of neighbouring rows meet.
struct LeoDispatchTreeGuide: View {
    static let lineWidth: CGFloat = 1.5
    static let elbowRadius: CGFloat = 4
    /// The elbow's horizontal run: from its column's centre to the next
    /// column, where the row's content starts.
    static let elbowRun: CGFloat = LeoDispatchRowPresentation.indentPerLevel / 2

    /// Per level `0...depth` (see `LeoDispatchGuides.continuing`), already
    /// clamped to the indent's deepest level.
    let continuing: [Bool]

    var body: some View {
        Canvas { context, size in
            let style = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            let shading = GraphicsContext.Shading.color(Color(nsColor: .separatorColor))
            let midY = size.height / 2
            for (level, carries) in continuing.enumerated() {
                let x = Self.columnCenter(level)
                if carries {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: shading, style: style)
                }
                if level == continuing.count - 1 {
                    var elbow = Path()
                    elbow.move(to: CGPoint(x: x, y: 0))
                    elbow.addLine(to: CGPoint(x: x, y: midY - Self.elbowRadius))
                    elbow.addQuadCurve(to: CGPoint(x: x + Self.elbowRadius, y: midY), control: CGPoint(x: x, y: midY))
                    elbow.addLine(to: CGPoint(x: x + Self.elbowRun, y: midY))
                    context.stroke(elbow, with: shading, style: style)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Level `n`'s line sits in the middle of its own `indentPerLevel` column.
    static func columnCenter(_ level: Int) -> CGFloat {
        CGFloat(level) * LeoDispatchRowPresentation.indentPerLevel + LeoDispatchRowPresentation.indentPerLevel / 2
    }
}
