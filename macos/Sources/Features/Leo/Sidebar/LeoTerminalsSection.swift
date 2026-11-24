import SwiftUI

/// The sidebar's Terminals section: this window's shells under their
/// titles. It observes the rows itself, and each row its own title, so a
/// terminal retitling redraws its row and not the section or the sidebar
/// above it (see `LeoWindowTerminals.list`, `LeoTerminalTitles`).
///
/// Never collapsible (B-167): `sidebarList` reads this section as its
/// header plus one row per terminal (`labels.count + 1`), so a hidden
/// section would count agent rows as terminals. A plain sidebar
/// `Section` collapses on hover under macOS 13 (the deployment
/// target); macOS 14+ only does so with `isExpanded:`, which this
/// section never passes, so `collapsible(false)` is a no-op there.
///
/// Its header moves the section (B-438): Move Up and Move Down in its
/// context menu, or a drag.
struct LeoTerminalsSection: View {
    @ObservedObject var titles: LeoTerminalTitles
    /// Its window's rows: what each row acts through.
    let terminals: LeoWindowTerminals
    let mover: LeoSidebarSectionMover

    var body: some View {
        Section(header: header) {
            ForEach(titles.rows) { title in
                LeoTerminalTitleRow(title: title, terminals: terminals)
                    .frame(minHeight: LeoDispatchRowMetrics.terminalRowHeight)
                    .listRowInsets(EdgeInsets())
                    .tag(Optional(LeoSidebarItemID.terminal(title.id)))
                    .id(LeoSidebarItemID.terminal(title.id))
            }
        }
        .collapsible(false)
    }

    private var header: some View {
        Text("Terminals")
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu { LeoSidebarSectionMoveItems(mover: mover) }
            .leoSidebarSectionDrag(mover)
    }
}

/// A Terminals row that observes its own title, so a retitle redraws it
/// and not the List around it (see `LeoTerminalTitles`).
private struct LeoTerminalTitleRow: View {
    @ObservedObject var title: LeoTerminalTitle
    let terminals: LeoWindowTerminals

    var body: some View {
        LeoTerminalRowView(label: title.label, terminals: terminals)
    }
}
