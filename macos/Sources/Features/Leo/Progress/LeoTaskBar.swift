import SwiftUI
import LeoKit

/// The thin progress bar: filled to a percent, or an animated segment while
/// the amount is unknown. Stale is dimmed, failed red, done green. Under
/// Reduce Motion the unknown bar holds still.
struct LeoTaskBar: View {
    static let height: CGFloat = 3

    let kind: LeoAgentRowPresentation.Progress.Kind
    /// On the sidebar's selected (accent) row the bar draws in white.
    var isOnSelection = false
    var height: CGFloat = LeoTaskBar.height
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isWindowVisible = true

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if let fraction = kind.fraction {
                    Capsule().fill(fill).frame(width: max(geometry.size.width * fraction, height))
                } else if kind == .indeterminate {
                    indeterminate(width: geometry.size.width)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .background(LeoWindowVisibilityReader(isVisible: $isWindowVisible))
        .accessibilityHidden(true)
    }

    private var track: Color { isOnSelection ? .white.opacity(0.28) : .primary.opacity(0.12) }

    private var fill: Color {
        if isOnSelection { return kind.isStale ? .white.opacity(0.5) : .white }
        switch kind {
        case .failed: return .red
        case .succeeded: return .green
        case .stale: return .secondary.opacity(0.6)
        case .determinate, .indeterminate, .cancelled: return .accentColor
        }
    }

    @ViewBuilder private func indeterminate(width: CGFloat) -> some View {
        let segment = width * 0.35
        if reduceMotion {
            Capsule().fill(fill).frame(width: segment).offset(x: (width - segment) / 2)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isWindowVisible)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                Capsule().fill(fill).frame(width: segment).offset(x: -segment + (width + segment) * phase)
            }
        }
    }
}

extension LeoAgentRowPresentation.Progress.Kind {
    var isStale: Bool {
        if case .stale = self { true } else { false }
    }

    var tint: Color {
        switch self {
        case .failed: .red
        case .succeeded: .green
        case .stale, .cancelled: .secondary
        case .determinate, .indeterminate: .accentColor
        }
    }
}
