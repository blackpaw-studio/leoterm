import SwiftUI

/// What a dispatch row's guide has to reach upward to.
enum LeoDispatchParentLink: Equatable {
    /// The agent row above the first dispatch.
    case agent
    /// The parent dispatch row above its first child.
    case dispatch
    /// The previous row of a sibling's subtree.
    case sibling
}

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

    /// For each node (by depth, depth first), what sits directly above it in
    /// the tree: the agent row (the first node), its parent dispatch (a node
    /// deeper than the one before it), or a sibling's subtree (otherwise).
    static func parentLinks(depths: [Int]) -> [LeoDispatchParentLink] {
        depths.enumerated().map { index, depth in
            guard index > 0 else { return .agent }
            return depth > depths[index - 1] ? .dispatch : .sibling
        }
    }
}

/// Where a dispatch row's guide is drawn relative to its row. A row's content
/// is centred in its list row, leaving `LeoDispatchRowMetrics.siblingGap`
/// between neighbours' content, and the List clips nothing, so each guide
/// bleeds past its row by enough that a row's line and the next row's meet;
/// a first child's reaches up to its parent (a dispatch's content bottom, an
/// agent's line 2 including its bottom padding).
struct LeoDispatchGuideGeometry: Equatable {
    /// Lines overlap by this much so no hairline shows between rows.
    static let overlap: CGFloat = 1

    let rowHeight: CGFloat
    let topBleed: CGFloat
    let bottomBleed: CGFloat

    init(rowHeight: CGFloat, parent: LeoDispatchParentLink) {
        self.rowHeight = rowHeight
        let gap = LeoDispatchRowMetrics.siblingGap
        let halfGap = (gap / 2).rounded(.up) + Self.overlap
        bottomBleed = halfGap
        topBleed = switch parent {
        case .sibling: halfGap
        case .dispatch: gap + Self.overlap
        // The agent row keeps its own bottom padding below its pill.
        case .agent: LeoDispatchRowMetrics.agentToFirstGap + Self.overlap
        }
    }

    var canvasHeight: CGFloat { topBleed + rowHeight + bottomBleed }
    /// The row's vertical centre in canvas coordinates, where the elbow turns.
    var midY: CGFloat { topBleed + rowHeight / 2 }
    /// A line that carries on through the row: the whole canvas.
    var throughLine: ClosedRange<CGFloat> { 0...canvasHeight }
    /// The row's own elbow: from the top down to the centre.
    var elbowLine: ClosedRange<CGFloat> { 0...midY }
}

/// The guide drawn in a dispatch row's leading inset: rounded elbow into the
/// row, a through-line where siblings continue.
struct LeoDispatchTreeGuide: View {
    static let lineWidth: CGFloat = 1.5
    static let elbowRadius: CGFloat = 4
    /// The elbow's horizontal run: from its column's centre to the next
    /// column, where the row's content starts.
    static let elbowRun: CGFloat = LeoDispatchRowPresentation.indentPerLevel / 2

    /// Per level `0...depth` (see `LeoDispatchGuides.continuing`), already
    /// clamped to the indent's deepest level.
    let continuing: [Bool]
    let geometry: LeoDispatchGuideGeometry

    var body: some View {
        Canvas { context, _ in
            let style = StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round)
            let shading = GraphicsContext.Shading.color(Color(nsColor: .separatorColor))
            let midY = geometry.midY
            for (level, carries) in continuing.enumerated() {
                let x = Self.columnCenter(level)
                if carries {
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: geometry.throughLine.lowerBound))
                    line.addLine(to: CGPoint(x: x, y: geometry.throughLine.upperBound))
                    context.stroke(line, with: shading, style: style)
                }
                if level == continuing.count - 1 {
                    var elbow = Path()
                    elbow.move(to: CGPoint(x: x, y: geometry.elbowLine.lowerBound))
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
