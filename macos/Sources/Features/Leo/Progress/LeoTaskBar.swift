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

    private var fill: Color { LeoTaskBarFill(kind: kind, isOnSelection: isOnSelection).color }
}

/// The bar's fill as a value (hue + opacity) so the palette can be pinned by a
/// test without comparing `Color`s. Calm by default: done is a soft green, not
/// the full-strength system green, which glows on the capsule's glass.
struct LeoTaskBarFill: Equatable {
    enum Hue: Equatable { case white, red, green, accent, secondary }

    /// Done bars fade the system green; on the capsule's glass a full-strength
    /// one reads as neon.
    static let succeededOpacity = 0.55

    let hue: Hue
    let opacity: Double

    init(kind: LeoAgentRowPresentation.Progress.Kind, isOnSelection: Bool) {
        if isOnSelection {
            self.init(.white, kind.isStale ? 0.5 : 1)
            return
        }
        switch kind {
        case .failed: self.init(.red, 1)
        case .succeeded: self.init(.green, Self.succeededOpacity)
        case .stale: self.init(.secondary, 0.6)
        case .determinate, .indeterminate, .cancelled: self.init(.accent, 1)
        }
    }

    private init(_ hue: Hue, _ opacity: Double) {
        self.hue = hue
        self.opacity = opacity
    }

    var color: Color {
        let base: Color = switch hue {
        case .white: .white
        case .red: .red
        case .green: .green
        case .accent: .accentColor
        case .secondary: .secondary
        }
        return base.opacity(opacity)
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
