import AppKit
import LeoKit
import SwiftUI

/// The small circular indicator at the end of an agent row's name line (the
/// HIG's constrained-space progress indicator): a system spinner or pie for
/// a live task, a still muted pie for a stale one, a red glyph for a failure.
/// Selected rows draw it white, like the other sidebar accessories.
struct LeoTaskIndicatorView: View {
    /// A `.small` spinning `NSProgressIndicator` is 16 pt.
    static let size: CGFloat = 16

    let indicator: LeoTaskIndicator
    let isSelected: Bool

    var body: some View {
        Group {
            if case .failed = indicator {
                Image(systemName: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.body)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.red))
            } else {
                Spinner(indicator: indicator, isSelected: isSelected)
            }
        }
        .frame(width: Self.size, height: Self.size)
    }

    /// Updated in place: a row redraw must not recreate the view, or the
    /// spinner would restart.
    private struct Spinner: NSViewRepresentable {
        let indicator: LeoTaskIndicator
        let isSelected: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeNSView(context: Context) -> NSProgressIndicator {
            let view = NSProgressIndicator()
            view.style = .spinning
            view.controlSize = .small
            view.isDisplayedWhenStopped = true
            view.minValue = 0
            view.maxValue = 1
            return view
        }

        func updateNSView(_ view: NSProgressIndicator, context: Context) {
            // White on the accent highlight; the dark appearance draws a light spinner.
            view.appearance = isSelected ? NSAppearance(named: .darkAqua) : nil
            switch indicator {
            case .progress(let fraction?):
                view.stopAnimation(nil)
                view.isIndeterminate = false
                view.doubleValue = fraction
                view.alphaValue = 1
            case .progress(nil):
                view.isIndeterminate = true
                view.alphaValue = 1
                // Reduce Motion: the spokes stay, nothing turns.
                if reduceMotion { view.stopAnimation(nil) } else { view.startAnimation(nil) }
            case .stalled(let fraction):
                view.stopAnimation(nil)
                view.isIndeterminate = false
                view.doubleValue = fraction ?? 0
                // No public tint: dimming is the muted look.
                view.alphaValue = Self.mutedAlpha
            case .failed:
                break
            }
        }

        private static let mutedAlpha: CGFloat = 0.45
    }
}
