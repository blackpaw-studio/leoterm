import AppKit
import LeoKit
import SwiftUI

/// What the capsule's text measures against: the same fonts the view sets.
enum LeoActivityCapsuleFonts {
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let status = NSFont.systemFont(ofSize: 12)

    static func width(of text: String, role: LeoActivityCapsulePresentation.TextRole) -> CGFloat {
        let font = role == .title ? title : status
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The toolbar's activity capsule: a 32 pt glass capsule with the selected
/// agent's primary task, a 4 pt bar along its bottom edge and a count badge.
/// Always present: with no task it says the agent's state as plain text
/// beside a tinted dot ("No agent", disabled, for a terminal row or the
/// start screen). Click opens the Tasks popover.
struct LeoActivityCapsule: View {
    static let height: CGFloat = 32
    static let barHeight: CGFloat = 4

    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var terminals: LeoWindowTerminals
    let actions: LeoAgentActions
    @State private var showsPopover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The agent whose tasks show: the actionable row, unless a terminal row is selected.
    private var row: LeoAgentRow? { terminals.selection == nil ? model.actionableSelection : nil }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(LeoTaskTickSchedule(row?.tasks ?? .none)) { context in
                content(row, now: context.date, width: proxy.size.width)
            }
        }
        .frame(height: Self.height)
    }

    private func presentation(for row: LeoAgentRow?, now: Date, width: CGFloat) -> LeoActivityCapsulePresentation {
        guard let row else { return .noAgent(availableWidth: width) }
        return LeoActivityCapsulePresentation(
            tasks: row.tasks, state: .init(attention: row.attention, isWorking: row.activity == .working), now: now,
            availableWidth: width, measure: LeoActivityCapsuleFonts.width(of:role:))
    }

    private func content(_ row: LeoAgentRow?, now: Date, width: CGFloat) -> some View {
        let presentation = presentation(for: row, now: now, width: width)
        return Button { showsPopover.toggle() } label: {
            capsule(presentation)
        }
        .buttonStyle(.plain)
        .disabled(!presentation.isEnabled)
        .modifier(LeoActivityKeyboard { showsPopover.toggle() })
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.isEnabled ? "Shows every task" : "")
        // A selection change with no click (a shortcut) can land on a
        // non-agent row while the popover is open: close it, or it stays up
        // empty and can't be reopened.
        .onChange(of: presentation.isEnabled) { isEnabled in
            if !isEnabled { showsPopover = false }
        }
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            LeoActivityPopover(presentation: presentation.popover) { id in
                if let row { actions.dismissTask(host: row.host, agent: row.name, id: id) }
            }
            .background(LeoEscapeDismiss(isPresented: $showsPopover))
        }
    }

    private func capsule(_ presentation: LeoActivityCapsulePresentation) -> some View {
        HStack(spacing: 8) {
            glyph(presentation.glyph).fixedSize().layoutPriority(2)
            if let title = presentation.title {
                Text(title).font(.system(size: 13, weight: presentation.kind == .tasks ? .semibold : .regular))
                    .foregroundStyle(presentation.isEnabled ? Color.primary : Color.secondary)
                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
            }
            if presentation.variant == .full, let status = presentation.statusText {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
            Spacer(minLength: 0)
            if let badge = presentation.badge { badgeView(badge) }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            if let bar = presentation.bar { LeoTaskBar(kind: bar, height: Self.barHeight) }
        }
        .clipShape(Capsule())
        .modifier(LeoActivityGlass())
        .contentShape(Capsule())
    }

    @ViewBuilder private func glyph(_ glyph: LeoActivityCapsulePresentation.Glyph) -> some View {
        switch glyph {
        case .spinner:
            if reduceMotion {
                Image(systemName: "circle.dotted").foregroundStyle(Color.accentColor)
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
            }
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
        case .dot(let state): Circle().fill(Self.dotTint(state)).frame(width: 8, height: 8).frame(width: 14, height: 14)
        }
    }

    /// The idle dot's tint by state; no agent is muted.
    private static func dotTint(_ state: LeoActivityCapsulePresentation.AgentState?) -> Color {
        switch state {
        case .working: .blue
        case .idle: Color.secondary
        case .needsYou: .orange
        case .errored: .red
        case nil: Color.secondary.opacity(0.5)
        }
    }

    private func badgeView(_ badge: LeoActivityCapsulePresentation.Badge) -> some View {
        Text("\(badge.count)")
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 1)
            .foregroundStyle(badge.isRed ? Color.white : Color.primary)
            .background(Capsule().fill(badge.isRed ? Color.red : Color.primary.opacity(0.15)))
            .fixedSize()
            .layoutPriority(2)
            .accessibilityHidden(true)
    }
}

/// The capsule's own glass: the toolbar item is borderless, so the platter
/// AppKit would draw (a fixed 36 pt) isn't there and the capsule is exactly
/// 32 pt with its bar flush to the bottom edge.
private struct LeoActivityGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

/// Return opens the popover while the capsule has keyboard focus (Space is
/// the button's own). No `.focusable()`: it made a click give the capsule
/// the keyboard, so typing after the popover closed never reached the
/// terminal. Under Full Keyboard Access the button is still focusable.
private struct LeoActivityKeyboard: ViewModifier {
    let activate: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.return) {
                activate()
                return .handled
            }
        } else {
            content
        }
    }
}
