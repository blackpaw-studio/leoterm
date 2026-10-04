import AppKit
import SwiftUI

/// B-057: a row in the sidebar's Terminals section -- a plain shell in this
/// window, titled by its terminal. A click (or VoiceOver's press) shows it
/// in the window's content area, like an agent row's; the arrow keys only
/// select it. A title another row already shows carries a quiet
/// secondary suffix, "(2)", that stays visible however the title
/// truncates (B-068). Its context menu shows, splits, renames and closes
/// it (B-177).
struct LeoTerminalRowView: View {
    let label: LeoTerminalRowLabel
    /// Its window's rows: what the menu acts through.
    let terminals: LeoWindowTerminals
    @State private var showingRename = false

    private func activate() { terminals.activate(label.id) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            // A word space apart, not the icon's gap.
            HStack(spacing: 4) {
                Text(label.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let suffix = label.suffix {
                    Text(suffix)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            // On the whole label, so hovering the "(2)" shows it too (B-079).
            .help(label.help)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        // Every click inside the row is a row click, read from the mouse
        // events themselves (see `LeoRowClickCatcher`, B-048/B-049). A
        // Control-click or right-click is the context menu's, not a click.
        .background(LeoRowClickCatcher(identity: label.id) { _, clickCount in
            guard clickCount == 1 else { return }
            activate()
        }.accessibilityHidden(true))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label.text), terminal")
        .accessibilityAction { activate() }
        .accessibilityAction(named: LeoRowAccessibility.pressName) { activate() }
        .contextMenu { menu }
        .sheet(isPresented: $showingRename) {
            LeoTerminalRenameSheet(
                currentTitle: label.title,
                liveTitle: LeoTerminalRow.displayTitle(of: terminals.liveTitle(label.id) ?? "")
            ) { terminals.rename(label.id, to: $0) }
        }
    }

    /// Like Finder's or Mail's: what the row does first, the destructive
    /// item last. Split Left and Up stay in the Window menu.
    @ViewBuilder private var menu: some View {
        Button("Show") { activate() }
        Button("Split Right") { terminals.split(label.id, .right) }
        Button("Split Down") { terminals.split(label.id, .down) }
        Button("Rename\u{2026}") { showingRename = true }
        Divider()
        Button("Close") { terminals.closeFromMenu(label.id) }
    }
}
