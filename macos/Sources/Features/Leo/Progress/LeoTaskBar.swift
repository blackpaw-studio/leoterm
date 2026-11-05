import SwiftUI
import LeoKit

/// The thin progress bar: filled to a percent, or a still full-width accent
/// track at low opacity while the amount is unknown (no motion; the elapsed
/// time says it is running). Stale is dimmed, failed red, done green.
struct LeoTaskBar: View {
    static let height: CGFloat = 3

    let kind: LeoAgentRowPresentation.Progress.Kind
    /// On the sidebar's selected (accent) row the bar draws in white.
    var isOnSelection = false
    var height: CGFloat = LeoTaskBar.height

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if let fraction = kind.fraction {
                    Capsule().fill(fill).frame(width: max(geometry.size.width * fraction, height))
                } else if kind == .indeterminate {
                    Capsule().fill(indeterminateFill)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var track: Color { isOnSelection ? .white.opacity(0.28) : .primary.opacity(0.12) }

    private var indeterminateFill: Color { isOnSelection ? .white.opacity(0.5) : .accentColor.opacity(0.35) }

    private var fill: Color {
        if isOnSelection { return kind.isStale ? .white.opacity(0.5) : .white }
        switch kind {
        case .failed: return .red
        case .succeeded: return .green
        case .stale: return .secondary.opacity(0.6)
        case .determinate, .indeterminate, .cancelled: return .accentColor
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
