import LeoKit
import SwiftUI

/// A plugin's sidebar section, drawn like the other sections: the caption
/// header with a chevron, then the plugin's content as ordinary sidebar rows
/// that flow with the sidebar's own scrolling (no inner scroll view), laid out
/// like the Terminals rows. Collapsed until opened; "Hide Section" is in its
/// context menu.
struct LeoPluginSidebarSection: View {
    @ObservedObject var sections: LeoPluginSidebarSections
    /// Observed so the rows change when the plugin renders.
    @ObservedObject var slots: LeoPluginSlotStore
    let entry: LeoPluginSidebarSectionEntry
    @Environment(\.leoPluginSurfaces) private var surfaces

    var body: some View {
        let expanded = sections.isExpanded(entry)
        // A real Section header, like Terminals and the machine groups, so the
        // section reads as top level and not as a subsection of the machine
        // above it. SwiftUI's sidebar List never inserts rows into a section
        // that was empty when it first appeared, so a collapsed section holds
        // one invisible row.
        Section(
            header: header(expanded: expanded)
                .onAppear { if expanded { sections.ensureLoaded(entry) } }
                // The section's rows are on screen while its header is and it is open.
                .leoPluginReportsVisibility(to: surfaces, key: entry.slotKey, isActive: expanded)
        ) {
            if expanded, let surfaces {
                LeoPluginSectionRowsView(surfaces: surfaces, key: entry.slotKey)
            } else {
                Color.clear
                    .frame(height: 1)
                    .listRowInsets(EdgeInsets())
                    .accessibilityHidden(true)
            }
        }
        .collapsible(false)
        // Opening a section at runtime must build it afresh, like a launch with
        // it open does: SwiftUI's sidebar List doesn't swap the placeholder row
        // for the plugin's rows in place (the section stays empty).
        .id(LeoPluginSectionIdentity.make(entry: entry, expanded: expanded))
    }

    private func header(expanded: Bool) -> some View {
        Button { sections.toggle(entry) } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse \(entry.title)" : "Expand \(entry.title)")
        .accessibilityLabel("\(entry.title), \(entry.pluginName)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .contextMenu {
            Button("Hide Section") { sections.hide(entry) }
        }
    }
}

/// The rows of an open section, from the same `LeoPluginSlotContent` the pane
/// and the palette show: Loading, the plugin's items, Error with Retry, or the
/// unavailable notice.
private struct LeoPluginSectionRowsView: View {
    @ObservedObject var surfaces: LeoPluginSurfaces
    let key: LeoPluginSlotKey
    private let mint = LeoPluginGestureMint()

    var body: some View {
        switch surfaces.content(for: key) {
        case .loading:
            statusRow { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading…") } }
        case .error(let message):
            statusRow {
                HStack(spacing: 8) {
                    Text(message).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Retry") { surfaces.retry(key) }.buttonStyle(.link)
                }
            }
        case .notice(let message):
            statusRow { Text(message).lineLimit(2) }
        case .nodes(let nodes, _):
            ForEach(LeoPluginSectionRows.make(from: nodes)) { row in
                switch row {
                case .subheader(_, let title):
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .listRowInsets(LeoDispatchRowMetrics.agentRowInsets)
                case .item(_, let item):
                    LeoPluginSectionItemRow(item: item) { action in
                        surfaces.perform(action, gesture: mint.mint(.click), in: key)
                    }
                case .message(_, let title, let detail):
                    statusRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(title).lineLimit(2)
                            if let detail { Text(detail).font(.caption).lineLimit(2) }
                        }
                    }
                }
            }
        }
    }

    private func statusRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: LeoDispatchRowMetrics.terminalRowHeight, alignment: .leading)
            .listRowInsets(EdgeInsets())
    }
}

/// One plugin list item as a sidebar row: the Terminals row's geometry (leading
/// symbol, medium title, 32pt minimum height, the List's own side padding) with
/// the item's accessories on the right. A click runs the first action; the
/// context menu has them all.
private struct LeoPluginSectionItemRow: View {
    let item: LeoPluginNode.Item
    let perform: (LeoPluginAction) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = item.sfSymbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            ForEach(Array(item.accessories.enumerated()), id: \.offset) { _, accessory in
                accessoryView(accessory)
            }
        }
        .frame(minHeight: LeoDispatchRowMetrics.terminalRowHeight)
        .contentShape(Rectangle())
        .onTapGesture { if let first = item.actions.first { perform(first.action) } }
        .contextMenu {
            ForEach(LeoPluginActionPresentation.entries(for: item.actions), id: \.index) { entry in
                Button { perform(entry.action) } label: { Label(entry.title, systemImage: entry.sfSymbol) }
            }
        }
        .help(item.subtitle.map { "\(item.title)\n\($0)" } ?? item.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.actions.isEmpty ? [] : .isButton)
        .listRowInsets(EdgeInsets())
    }

    private func accessoryView(_ accessory: LeoPluginNode.Accessory) -> some View {
        HStack(spacing: 2) {
            if let symbol = accessory.sfSymbol { Image(systemName: symbol) }
            if !accessory.text.isEmpty { Text(accessory.text).lineLimit(1) }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(LeoPluginRenderStyle.ink(for: accessory.color).style(isSelected: false))
        .fixedSize()
        .help(accessory.help ?? accessory.text)
    }
}

/// The SwiftUI identity of a sidebar section: it changes with the open state, so
/// the List rebuilds the section on a toggle.
enum LeoPluginSectionIdentity {
    static func make(entry: LeoPluginSidebarSectionEntry, expanded: Bool) -> String {
        "\(entry.id)#\(expanded ? "open" : "closed")"
    }
}
