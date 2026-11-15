import SwiftUI

/// A sidebar section header. A collapsible one is a button -- the whole
/// title is the click target, and VoiceOver reads it as one that expands or
/// collapses. A fixed one (Needs You) is plain text. A count, when the
/// section shows one, trails the title; the alert count reads in orange.
struct LeoSidebarSectionHeader: View {
    let section: LeoSidebarSection
    let toggle: () -> Void

    var body: some View {
        if section.isCollapsible {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    titleAndCount
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(section.isCollapsed ? "Show \(section.title)" : "Hide \(section.title)")
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(section.isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityHint(section.isCollapsed ? "Shows this section’s agents" : "Hides this section’s agents")
        } else {
            HStack(spacing: 4) {
                titleAndCount
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityTitle)
        }
    }

    private var titleAndCount: some View {
        HStack(spacing: 4) {
            Text(section.title)
            if section.showsCount {
                Text("\(section.rows.count)")
                    .monospacedDigit()
                    .foregroundStyle(section.isAlert ? AnyShapeStyle(LeoTint.orange.color) : AnyShapeStyle(.tertiary))
            }
        }
    }

    private var accessibilityTitle: String {
        section.showsCount ? "\(section.title), \(section.rows.count)" : section.title
    }
}
