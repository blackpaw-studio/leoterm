import LeoKit
import SwiftUI

/// A plugin's sidebar section, drawn like the other sections: the caption
/// header with a chevron, then the plugin's content as one row. Collapsed
/// until opened; "Hide Section" is in its context menu.
struct LeoPluginSidebarSection: View {
    @ObservedObject var sections: LeoPluginSidebarSections
    /// Observed so the row grows or shrinks when the plugin renders.
    @ObservedObject var slots: LeoPluginSlotStore
    let entry: LeoPluginSidebarSectionEntry

    var body: some View {
        let expanded = sections.isExpanded(entry)
        let binding = LeoPluginSlotBinding(host: sections.host, key: entry.slotKey)
        // The title is a row, not the Section's header: SwiftUI's sidebar List
        // never inserts rows into a section that was empty when it first
        // appeared, so a collapsed section must still hold one row.
        Section {
            header(expanded: expanded)
            if expanded {
                LeoPluginSlotContent(binding: binding)
                    .frame(height: LeoPluginSectionLayout.height(for: binding.nodes))
                    .listRowInsets(EdgeInsets())
                    .onAppear { sections.ensureLoaded(entry) }
            }
        }
        .collapsible(false)
    }

    private func header(expanded: Bool) -> some View {
        Button { sections.toggle(entry) } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
                Text(entry.title)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .listRowInsets(LeoDispatchRowMetrics.agentRowInsets)
        .help(expanded ? "Collapse \(entry.title)" : "Expand \(entry.title)")
        .accessibilityLabel("\(entry.title), \(entry.pluginName)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .contextMenu {
            Button("Hide Section") { sections.hide(entry) }
        }
    }
}

/// How tall an open section is: its list's rows, within a floor and a cap so
/// a long list scrolls inside the sidebar rather than pushing the agents off it.
enum LeoPluginSectionLayout {
    static let minimumHeight: CGFloat = 72
    static let maximumHeight: CGFloat = 260
    static let defaultHeight: CGFloat = 120
    /// The list's own insets above and below its rows.
    static let contentMargin: CGFloat = 16

    static func height(for nodes: [LeoPluginNode]) -> CGFloat {
        let wanted = nodes.reduce(CGFloat(0)) { $0 + height(of: $1) } + contentMargin
        return min(max(wanted, minimumHeight), maximumHeight)
    }

    private static func height(of node: LeoPluginNode) -> CGFloat {
        guard case .list(let list) = node else { return defaultHeight }
        return list.sections.reduce(CGFloat(0)) { total, section in
            let header = section.title == nil ? 0 : LeoPluginRenderStyle.headerRowHeight
            return total + header + CGFloat(section.items.count) * LeoPluginRenderStyle.itemRowHeight
        }
    }
}
