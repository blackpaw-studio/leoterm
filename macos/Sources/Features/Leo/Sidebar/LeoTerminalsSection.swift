import SwiftUI

/// The sidebar's Terminals section: this window's shells under their
/// titles. It observes the titles itself, so a terminal retitling redraws
/// this section and not the sidebar above it (see `LeoWindowTerminals.list`).
///
/// Never collapsible (B-167): `sidebarList` reads this section as its
/// header plus one row per terminal (`labels.count + 1`), so a hidden
/// section would count agent rows as terminals. A plain sidebar
/// `Section` collapses on hover under macOS 13 (the deployment
/// target); macOS 14+ only does so with `isExpanded:`, which this
/// section never passes, so `collapsible(false)` is a no-op there.
struct LeoTerminalsSection: View {
    @ObservedObject var titles: LeoTerminalTitles
    /// Its window's rows: what each row acts through.
    let terminals: LeoWindowTerminals

    var body: some View {
        Section(header: Text("Terminals")) {
            ForEach(titles.labels) { label in
                LeoTerminalRowView(label: label, terminals: terminals)
                    .frame(minHeight: LeoDispatchRowMetrics.terminalRowHeight)
                    .listRowInsets(EdgeInsets())
                    .tag(Optional(LeoSidebarItemID.terminal(label.id)))
                    .id(LeoSidebarItemID.terminal(label.id))
            }
        }
        .collapsible(false)
    }
}
