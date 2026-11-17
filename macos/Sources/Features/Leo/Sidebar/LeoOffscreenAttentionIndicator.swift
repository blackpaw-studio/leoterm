import AppKit
import SwiftUI

/// B-413 (P2): the capsule at the sidebar's top or bottom edge that says an
/// agent needing you is scrolled out of view. Calm: it appears and goes
/// without motion, only when the row's own Needs You, Error or unread state
/// is off screen, and a click scrolls the nearest such row to the middle of
/// the list without selecting or attaching anything.
///
/// Drawn by SwiftUI, but wrapped in an AppKit view that is the one
/// accessibility element (a button, reachable by VoiceOver and Full
/// Keyboard Access): SwiftUI's own accessibility tree isn't there to read in
/// a hosted test.
struct LeoOffscreenAttentionIndicator: NSViewRepresentable {
    let presentation: LeoOffscreenAttention.Presentation
    let scroll: () -> Void

    func makeNSView(context: Context) -> LeoOffscreenAttentionPillView { LeoOffscreenAttentionPillView() }

    func updateNSView(_ view: LeoOffscreenAttentionPillView, context: Context) {
        view.update(presentation: presentation, scroll: scroll)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LeoOffscreenAttentionPillView, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}

/// The capsule's look: orange for needs you, red for an error, the accent
/// for unread (the row's own hues).
struct LeoOffscreenAttentionPillLabel: View {
    let presentation: LeoOffscreenAttention.Presentation

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.edge.symbolName).imageScale(.small)
            Text(presentation.text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .fixedSize()
    }

    private var ink: Color {
        switch presentation.target.kind {
        case .needsYou: LeoTint.orange.color
        case .error: LeoTint.red.color
        case .unread: Color.accentColor
        }
    }
}

final class LeoOffscreenAttentionPillView: NSView {
    private var presentation: LeoOffscreenAttention.Presentation?
    private var scroll: () -> Void = {}
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        focusRingType = .exterior
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func update(presentation: LeoOffscreenAttention.Presentation, scroll: @escaping () -> Void) {
        self.presentation = presentation
        self.scroll = scroll
        host.rootView = AnyView(LeoOffscreenAttentionPillLabel(presentation: presentation))
        toolTip = presentation.accessibilityLabel
        invalidateIntrinsicContentSize()
        frame.size = fittingSize
    }

    override var fittingSize: NSSize { host.fittingSize }
    override var intrinsicContentSize: NSSize { host.fittingSize }

    // MARK: Pointer and keyboard

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { scroll() }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { scroll() } else { super.keyDown(with: event) }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { presentation?.accessibilityLabel }
    override func accessibilityHelp() -> String? { presentation?.hint }
    override func accessibilityIdentifier() -> String { presentation?.edge.identifier ?? "" }

    override func accessibilityPerformPress() -> Bool {
        scroll()
        return true
    }
}

/// The indicators over the sidebar list, one per edge, each shown only
/// while a row needing you is off that edge.
struct LeoOffscreenAttentionOverlay: ViewModifier {
    /// Every listed agent row that needs you, with its table-row index.
    let candidates: [LeoOffscreenAttention.Candidate]
    /// How many table rows `candidates`' indices were counted over; a table
    /// with fewer rows means the count has drifted from the list, and the
    /// indicators stay quiet rather than point at the wrong row.
    let mirroredRowCount: Int
    let proxy: ScrollViewProxy
    @StateObject private var tracker = LeoSidebarViewportTracker()
    @State private var anchor = LeoListLayoutAnchor()

    /// What a re-measure follows: the rows' needing you, or their positions.
    private struct Trigger: Equatable {
        let candidates: [LeoOffscreenAttention.Candidate]
        let mirroredRowCount: Int
    }

    func body(content: Content) -> some View {
        content
            .background(LeoSidebarViewportFinder(tracker: tracker).accessibilityHidden(true))
            .background(LeoListLayoutAnchorBackdrop(anchor: anchor).accessibilityHidden(true))
            .overlay(alignment: .top) { indicator(.top, target: targets.above, count: counts.above) }
            .overlay(alignment: .bottom) { indicator(.bottom, target: targets.below, count: counts.below) }
            .onChange(of: Trigger(candidates: candidates, mirroredRowCount: mirroredRowCount)) { _ in
                // The list lays out the change first, so its rows have moved.
                anchor.request { [tracker] in tracker.refresh() }
            }
    }

    private var visibleRows: ClosedRange<Int>? {
        guard let viewport = tracker.viewport, mirroredRowCount <= viewport.numberOfRows else { return nil }
        return viewport.visibleRows
    }

    private var targets: LeoOffscreenAttention.Targets {
        LeoOffscreenAttention.targets(of: candidates, visibleRows: visibleRows)
    }

    private var counts: (above: Int, below: Int) {
        LeoOffscreenAttention.offscreenCounts(of: candidates, visibleRows: visibleRows)
    }

    @ViewBuilder private func indicator(_ edge: LeoOffscreenAttention.Edge, target: LeoOffscreenAttention.Candidate?, count: Int) -> some View {
        if let target {
            LeoOffscreenAttentionIndicator(
                presentation: LeoOffscreenAttention.presentation(edge: edge, target: target, offscreenCount: count)
            ) { proxy.scrollTo(LeoSidebarItemID.agent(target.id), anchor: .center) }
            .padding(6)
        }
    }
}

extension View {
    func leoShowsOffscreenAttention(
        _ candidates: [LeoOffscreenAttention.Candidate], mirroredRowCount: Int, proxy: ScrollViewProxy
    ) -> some View {
        modifier(LeoOffscreenAttentionOverlay(candidates: candidates, mirroredRowCount: mirroredRowCount, proxy: proxy))
    }
}
