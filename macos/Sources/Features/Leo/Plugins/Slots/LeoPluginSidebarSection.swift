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
    /// Moves the section among the sidebar's others (B-438).
    let mover: LeoSidebarSectionMover
    @Environment(\.leoPluginSurfaces) private var surfaces

    var body: some View {
        let expanded = sections.isExpanded(entry)
        // A real Section header, like Terminals and the machine groups, so the
        // section reads as top level and not as a subsection of the machine
        // above it. A collapsed section lists no rows (B-438: an invisible
        // placeholder row left a gap above the next section). SwiftUI's
        // sidebar List never inserts rows into a section that was empty when
        // it first appeared, but opening one builds a new section (see `.id`).
        Section(
            header: header(expanded: expanded)
                .onAppear { if expanded { sections.ensureLoaded(entry) } }
                // The section's rows are on screen while its header is and it is open.
                .leoPluginReportsVisibility(to: surfaces, key: entry.slotKey, isActive: expanded)
        ) {
            if expanded, let surfaces {
                LeoPluginSectionRowsView(surfaces: surfaces, key: entry.slotKey)
            }
        }
        .collapsible(false)
        // Opening a section at runtime must build it afresh, like a launch with
        // it open does: SwiftUI's sidebar List doesn't add the plugin's rows to
        // the section in place (it stays empty).
        .id(LeoPluginSectionIdentity.make(entry: entry, expanded: expanded))
    }

    @ViewBuilder private func header(expanded: Bool) -> some View {
        if let surfaces {
            LeoPluginObservedSectionHeader(
                surfaces: surfaces, entry: entry, expanded: expanded, mover: mover,
                toggle: { sections.toggle(entry) }, hide: { sections.hide(entry) })
        } else {
            LeoPluginSectionHeader(
                entry: entry, expanded: expanded, accessory: nil, mover: mover,
                toggle: { sections.toggle(entry) }, hide: { sections.hide(entry) })
        }
    }

    /// The table rows a section takes: its header, then each row `body`
    /// lists under it. `content` is nil while it is collapsed or there are
    /// no plugin surfaces, when it lists nothing. B-438 counts these for
    /// the sections below it.
    static func tableRows(listing content: LeoPluginSlotContent?) -> Int {
        1 + LeoPluginSectionListing.rows(for: content).count
    }
}

/// What a plugin section lists under its header, one entry per table row:
/// a status row while it loads, fails or is unavailable, else the plugin's
/// rows. `LeoPluginSectionRowsView` draws exactly these, and the sidebar
/// counts them (B-438).
enum LeoPluginSectionListing: Equatable, Identifiable {
    case loading
    case error(String)
    case notice(String)
    case row(LeoPluginSectionRows.Row)

    var id: String {
        switch self {
        case .loading: "status.loading"
        case .error: "status.error"
        case .notice: "status.notice"
        case .row(let row): "row.\(row.id)"
        }
    }

    /// Nothing while the section is collapsed (`content` is nil).
    static func rows(for content: LeoPluginSlotContent?) -> [LeoPluginSectionListing] {
        switch content {
        case nil: []
        case .loading: [.loading]
        case .error(let message): [.error(message)]
        case .notice(let message): [.notice(message)]
        case .nodes(let nodes, _): LeoPluginSectionRows.make(from: nodes).map(Self.row)
        }
    }
}

/// Reads the slot's last render for the header accessory, so it stays current
/// while the section is collapsed.
private struct LeoPluginObservedSectionHeader: View {
    @ObservedObject var surfaces: LeoPluginSurfaces
    let entry: LeoPluginSidebarSectionEntry
    let expanded: Bool
    let mover: LeoSidebarSectionMover
    let toggle: () -> Void
    let hide: () -> Void

    var body: some View {
        LeoPluginSectionHeader(
            entry: entry, expanded: expanded, accessory: accessory, mover: mover, toggle: toggle, hide: hide)
    }

    private var accessory: LeoPluginNode.Accessory? {
        guard case .nodes(let nodes, _) = surfaces.content(for: entry.slotKey) else { return nil }
        return LeoPluginSectionRows.layout(from: nodes).headerAccessory
    }
}

/// Chevron, title and, at the trailing edge, the plugin's header accessory
/// (a slot root that starts with an Accessory), shown collapsed or open. With
/// a `mover`, a drop lands on the whole header and the drag starts from the
/// button's label (B-438).
struct LeoPluginSectionHeader: View {
    let entry: LeoPluginSidebarSectionEntry
    let expanded: Bool
    let accessory: LeoPluginNode.Accessory?
    var mover: LeoSidebarSectionMover?
    let toggle: () -> Void
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 0) { headerButton }
            .modifier(SectionDropTarget(mover: mover))
    }

    private var headerButton: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let accessory { LeoPluginSectionAccessory(accessory: accessory).accessibilityHidden(true) }
            }
            .contentShape(Rectangle())
            .modifier(SectionDragSource(mover: mover))
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse \(entry.title)" : "Expand \(entry.title)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .contextMenu {
            Button("Hide Section", action: hide)
            if let mover {
                Divider()
                LeoSidebarSectionMoveItems(mover: mover)
            }
        }
    }

    private var accessibilityLabel: String {
        [entry.title, entry.pluginName, accessory?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private struct SectionDropTarget: ViewModifier {
        let mover: LeoSidebarSectionMover?
        @ViewBuilder func body(content: Content) -> some View {
            if let mover { content.leoSidebarSectionDropTarget(mover) } else { content }
        }
    }

    private struct SectionDragSource: ViewModifier {
        let mover: LeoSidebarSectionMover?
        @ViewBuilder func body(content: Content) -> some View {
            if let mover { content.leoSidebarSectionDragSource(mover) } else { content }
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
        let listing = LeoPluginSectionListing.rows(for: surfaces.content(for: key))
        let labelColumn = LeoPluginSectionMeter.labelColumn(for: listing.compactMap(\.pluginRow))
        ForEach(listing) { listed in
            switch listed {
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
            case .row(let row):
                LeoPluginSectionRowView(row: row, labelColumn: labelColumn) { action in
                    surfaces.perform(action, gesture: mint.mint(.click), in: key)
                }
            }
        }
    }

    private func statusRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        sectionStatusRow(content)
    }
}

private extension LeoPluginSectionListing {
    var pluginRow: LeoPluginSectionRows.Row? {
        if case .row(let row) = self { row } else { nil }
    }
}

private func sectionStatusRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: LeoDispatchRowMetrics.terminalRowHeight, alignment: .leading)
        .listRowInsets(EdgeInsets())
}

/// A rendered slot's body as sidebar rows (the header accessory is drawn by
/// `LeoPluginSectionHeader`). `perform` gets the clicked action.
struct LeoPluginSectionNodeRows: View {
    let nodes: [LeoPluginNode]
    let perform: (LeoPluginAction) -> Void

    var body: some View {
        let rows = LeoPluginSectionRows.layout(from: nodes).rows
        let labelColumn = LeoPluginSectionMeter.labelColumn(for: rows)
        ForEach(rows) { row in
            LeoPluginSectionRowView(row: row, labelColumn: labelColumn, perform: perform)
        }
    }
}

/// One plugin row of a section, drawn by its kind.
private struct LeoPluginSectionRowView: View {
    let row: LeoPluginSectionRows.Row
    let labelColumn: CGFloat?
    let perform: (LeoPluginAction) -> Void

    var body: some View {
        switch row {
        case .subheader(_, let title):
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .listRowInsets(LeoDispatchRowMetrics.agentRowInsets)
        case .item(_, let item):
            LeoPluginSectionItemRow(item: item, perform: perform)
        case .message(_, let title, let detail):
            sectionStatusRow {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).lineLimit(2)
                    if let detail { Text(detail).font(.caption).lineLimit(2) }
                }
            }
        case .group(_, let group):
            LeoPluginSectionGroupRow(group: group, labelColumn: labelColumn, perform: perform)
        case .meter(_, let meter):
            LeoPluginSectionMeterRow(meter: meter, labelColumn: labelColumn)
        case .action(_, let labeled):
            // A click mints a gesture (via `perform`), so the callback may open a prompt.
            LeoPluginInlineActionButton(entry: LeoPluginActionPresentation.entry(for: labeled)) { perform(labeled.action) }
                .listRowInsets(LeoDispatchRowMetrics.agentRowInsets)
        }
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
