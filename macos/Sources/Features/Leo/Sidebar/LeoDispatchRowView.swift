import AppKit
import SwiftUI

/// One live dispatch under its agent row: indented by depth, dimmed and
/// inert with its agent rows when disconnected. Informational (no tag,
/// never selected) unless the daemon can attach to it (B-266): then
/// `click` is set, the list tags it, and a click opens it.
struct LeoDispatchRowView: View {
    /// Fixed so every dispatch row is the same height whatever its content.
    static let rowHeight: CGFloat = 22
    static let dotSize: CGFloat = 6
    static let pulseDuration: Double = 0.9
    static let pulseDimmedOpacity: Double = 0.35

    let node: LeoDispatchNode
    /// Set only for a selectable row: the click's modifiers and count.
    var click: ((NSEvent.ModifierFlags, Int) -> Void)?
    /// Set only when the dispatch has children: shows a disclosure control
    /// (outside the row's click area) that calls `toggle`.
    var disclosure: Disclosure?
    /// The tree-guide flags per level (see `LeoDispatchGuides`).
    var guides: [Bool] = []
    /// What the guide reaches up to (see `LeoDispatchGuideGeometry`).
    var parentLink: LeoDispatchParentLink = .sibling
    /// Whether this row is the list's selection: its tinted parts go white.
    var isSelected = false

    struct Disclosure {
        let isCollapsed: Bool
        let toggle: () -> Void
    }

    var body: some View {
        let presentation = LeoDispatchRowPresentation(node)
        HStack(spacing: 0) {
            let geometry = LeoDispatchGuideGeometry(rowHeight: Self.rowHeight, parent: parentLink)
            LeoDispatchTreeGuide(
                continuing: Array(guides.prefix(LeoDispatchRowPresentation.maxIndentDepth + 1)), geometry: geometry
            )
            .frame(width: presentation.indent)
            // Bleeds past the row (never resizes it) so neighbouring lines meet.
            .padding(.top, -geometry.topBleed)
            .padding(.bottom, -geometry.bottomBleed)
            HStack(spacing: 6) {
                label(presentation)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.accessibilityLabel)
                    .modifier(Interaction(click: click, id: node.id))
                if let disclosure { disclosureButton(disclosure) }
                trailingStatus
                    .modifier(Interaction(click: click, id: node.id))
            }
        }
        .frame(height: Self.rowHeight)
        .help(presentation.title)
    }

    private func label(_ presentation: LeoDispatchRowPresentation) -> some View {
        HStack(spacing: 6) {
            if let chip = presentation.roleChip { LeoRoleChipView(chip: chip, isSelected: isSelected) }
            if presentation.showsTitle {
                Text(presentation.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            Spacer(minLength: 4)
        }
    }

    /// Re-read once a minute, the resolution the text has.
    private var trailingStatus: some View {
        TimelineView(.everyMinute) { context in
            LeoDispatchStatusView(status: LeoDispatchRowPresentation(node, now: context.date).status, isSelected: isSelected)
        }
    }

    private func disclosureButton(_ disclosure: Disclosure) -> some View {
        Button(action: disclosure.toggle) {
            Image(systemName: disclosure.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(disclosure.isCollapsed ? "Show nested dispatches" : "Hide nested dispatches")
        .leoSelectionDisabled()
    }

    /// A selectable row takes the same whole-row click catcher as an
    /// agent row; the rest stay out of selection.
    private struct Interaction: ViewModifier {
        let click: ((NSEvent.ModifierFlags, Int) -> Void)?
        let id: String

        func body(content: Content) -> some View {
            if let click {
                content
                    .contentShape(Rectangle())
                    .background(LeoRowClickCatcher(identity: id, onClick: click).accessibilityHidden(true))
                    .accessibilityAddTraits(.isButton)
            } else {
                content.leoSelectionDisabled()
            }
        }
    }
}

private extension View {
    /// Keeps arrow keys and clicks off the row where the OS supports it;
    /// on macOS 13 the missing tag alone keeps it unselectable.
    @ViewBuilder func leoSelectionDisabled() -> some View {
        if #available(macOS 14, *) {
            selectionDisabled()
        } else {
            self
        }
    }
}
