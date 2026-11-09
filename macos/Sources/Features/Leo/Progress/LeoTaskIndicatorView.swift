import AppKit
import LeoKit
import SwiftUI

/// The small circular indicator at the end of an agent row's name line (the
/// HIG's constrained-space progress indicator): the system spinner for an
/// indeterminate live task, a pie for a determinate one, the same pie muted
/// and still for a stale one, and a red glyph for a failure. Over the accent
/// highlight it draws white, like the other sidebar accessories (the pie's
/// hierarchical styles adapt on their own).
///
/// The pie is drawn here rather than by `NSProgressIndicator`: hosted in a
/// selected row, the system pie takes the accent colour and disappears into
/// the highlight, and it has no muted state.
struct LeoTaskIndicatorView: View {
    /// A `.small` spinning `NSProgressIndicator` is 16 pt.
    static let size: CGFloat = 16

    let indicator: LeoTaskIndicator
    let isSelected: Bool
    /// What a click on a spinner does. The pie and glyph are not AppKit
    /// views, so the click target laid over them gets the mouse; the
    /// spinner is one, and sits above that target.
    var onClick: () -> Void = {}

    var body: some View {
        OnAccentReader(isSelected: isSelected) { isOnAccent in content(isOnAccent: isOnAccent) }
            .frame(width: Self.size, height: Self.size)

    }

    private func content(isOnAccent: Bool) -> some View {
        Group {
            switch indicator {
            case .progress(nil): Spinner(isOnAccent: isOnAccent, onClick: onClick)
            case .progress(let fraction?): Pie(fraction: fraction, ring: AnyShapeStyle(.secondary), fill: AnyShapeStyle(.primary))
            case .stalled(let fraction): Pie(fraction: fraction ?? 0, ring: AnyShapeStyle(.quaternary), fill: AnyShapeStyle(.tertiary))
            case .failed: failedGlyph(isOnAccent: isOnAccent)
            }
        }
    }

    private func failedGlyph(isOnAccent: Bool) -> some View {
        Image(systemName: "exclamationmark.circle.fill")
            .symbolRenderingMode(.monochrome)
            .font(.system(size: Self.size))
            .foregroundStyle(isOnAccent ? Color.white : Color.red)
    }

    /// A ring with a wedge filled clockwise from 12 o'clock.
    struct Pie: View {
        static let ringWidth: CGFloat = 1.5
        static let gap: CGFloat = 2

        let fraction: Double
        let ring: AnyShapeStyle
        let fill: AnyShapeStyle

        var body: some View {
            ZStack {
                Circle().strokeBorder(ring, lineWidth: Self.ringWidth)
                Wedge(fraction: min(max(fraction, 0), 1))
                    .fill(fill)
                    .padding(Self.ringWidth + Self.gap)
            }
        }
    }

    struct Wedge: Shape {
        var fraction: Double

        func path(in rect: CGRect) -> Path {
            guard fraction > 0 else { return Path() }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            if fraction >= 1 { return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)) }
            var path = Path()
            path.move(to: center)
            path.addArc(
                center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
            path.closeSubpath()
            return path
        }
    }

    /// The spinner is an AppKit view layered above the row's click target,
    /// so it takes the click itself (and, like the target, is no row click).
    private final class ClickableIndicator: NSProgressIndicator, LeoRowClickExempt {
        var action: () -> Void = {}
        private var isArmed = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { isArmed = contains(event) }

        override func mouseUp(with event: NSEvent) {
            defer { isArmed = false }
            guard isArmed, contains(event) else { return }
            action()
        }

        private func contains(_ event: NSEvent) -> Bool { bounds.contains(convert(event.locationInWindow, from: nil)) }
    }

    /// The system spinner for an indeterminate task. Updated in place: a row
    /// redraw must not recreate the view, or the spinner would restart.
    private struct Spinner: NSViewRepresentable {
        let isOnAccent: Bool
        let onClick: () -> Void
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeNSView(context: Context) -> NSProgressIndicator {
            let view = ClickableIndicator()
            view.style = .spinning
            view.controlSize = .small
            view.isIndeterminate = true
            view.isDisplayedWhenStopped = true
            return view
        }

        func updateNSView(_ view: NSProgressIndicator, context: Context) {
            (view as? ClickableIndicator)?.action = onClick
            // White on the accent highlight; the dark appearance draws light spokes.
            view.appearance = isOnAccent ? NSAppearance(named: .darkAqua) : nil
            // Reduce Motion: the spokes stay, nothing turns.
            if reduceMotion { view.stopAnimation(nil) } else { view.startAnimation(nil) }
        }
    }
}

/// Whether the row is drawn over the accent highlight. A grey (unfocused)
/// selection is not: white would vanish on it. Before macOS 14, which has no
/// background prominence, any selected row counts.
private struct OnAccentReader<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        if #available(macOS 14, *) {
            Prominent(isSelected: isSelected, content: content)
        } else {
            content(isSelected)
        }
    }

    @available(macOS 14, *)
    private struct Prominent: View {
        let isSelected: Bool
        let content: (Bool) -> Content
        @Environment(\.backgroundProminence) private var prominence

        var body: some View { content(isSelected && prominence == .increased) }
    }
}
