import CoreGraphics
import LeoKit

/// The pure layout of a `Meter`: where each toned segment starts and how wide
/// it is. Values are fractions of `max` of the drawn width; a segment that
/// would pass the end is cut there and later ones are dropped, so a plugin
/// can't draw outside its bar.
enum LeoPluginMeterGeometry {
    /// In a pane summary a meter is a fixed 56 × 5 pt bar.
    static let summarySize = CGSize(width: 56, height: 5)
    /// In a body it fills the available width at this height.
    static let bodyHeight: CGFloat = 6

    struct Bar: Equatable {
        let x: CGFloat
        let width: CGFloat
        let tone: LeoPluginTone
    }

    static func bars(_ segments: [LeoPluginNode.Meter.Segment], max total: Double, width: CGFloat) -> [Bar] {
        guard width > 0, total > 0 else { return [] }
        var bars: [Bar] = []
        var x: CGFloat = 0
        for segment in segments where x < width {
            let drawn = Swift.min(CGFloat(segment.value / total) * width, width - x)
            guard drawn > 0 else { continue }
            bars.append(Bar(x: x, width: drawn, tone: segment.tone))
            x += drawn
        }
        return bars
    }
}
