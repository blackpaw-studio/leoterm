import AppKit
import SwiftUI

/// B-065: a button in the sidebar's footer bar. Each is a main-menu item
/// in button form, not a copy: it sends the item's own action, is labelled
/// with the item's title, and its tooltip names the item's live shortcut
/// (B-080), so the menu item and its shortcut stay the way in (P1).
enum LeoSidebarButton: CaseIterable, Identifiable {
    /// File ▸ New Terminal (⌘T): a plain-shell row in this window (B-057).
    case newTerminal
    /// View ▸ Quick Terminal: Ghostty's drop-down terminal.
    case quickTerminal

    var id: Self { self }

    /// The menu item's title.
    var title: String {
        switch self {
        case .newTerminal: LeoWindowTabbing.newTerminalTitle
        case .quickTerminal: "Quick Terminal"
        }
    }

    var accessibilityLabel: String { title }

    var systemImage: String {
        switch self {
        case .newTerminal: "terminal"
        // The quick terminal drops down from the top of the screen.
        case .quickTerminal: "rectangle.tophalf.inset.filled"
        }
    }

    /// The menu item's action.
    var action: Selector {
        switch self {
        case .newTerminal: LeoShortcutHints.newTerminalAction
        case .quickTerminal: LeoShortcutHints.quickTerminalAction
        }
    }

    /// The menu item's current shortcut, or nil when it has none.
    @MainActor func hint(in hints: LeoShortcutHints) -> String? {
        switch self {
        case .newTerminal: hints.newTerminal
        case .quickTerminal: hints.quickTerminal
        }
    }

    /// "<Title> <shortcut>", or the title alone when the item is unbound:
    /// no hint beats a wrong one.
    func tooltip(hint: String?) -> String {
        guard let hint, !hint.isEmpty else { return title }
        return "\(title) \(hint)"
    }

    /// Sends the menu item's action to `target`, as the item would. For New
    /// Terminal that is the button's own window's controller, so the row
    /// lands in the window that was clicked even if another is key. With no
    /// target it goes up the key window's responder chain. Returns whether
    /// anything handled it.
    @MainActor @discardableResult
    func send(to target: AnyObject?) -> Bool {
        NSApp.sendAction(action, to: target, from: nil)
    }
}

/// The sidebar's footer: a quiet row of icon buttons pinned below the list
/// (the Finder/Mail sidebar convention), so it stays put however long the
/// list grows and whatever state the daemon is in -- neither button needs
/// it.
struct LeoSidebarButtonBar: View {
    @ObservedObject var hints: LeoShortcutHints
    let perform: (LeoSidebarButton) -> Void

    /// Each button's clickable area: an SF Symbol alone is a small target.
    private static let hitSize: CGFloat = 22

    var body: some View {
        VStack(spacing: LeoSidebarChromeMetrics.itemSpacing) {
            Divider()
            HStack(spacing: LeoSidebarChromeMetrics.itemSpacing) {
                ForEach(LeoSidebarButton.allCases) { button in
                    Button {
                        perform(button)
                    } label: {
                        Image(systemName: button.systemImage)
                            .frame(width: Self.hitSize, height: Self.hitSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    // Clicking one must not pull focus off the terminal.
                    .focusable(false)
                    .foregroundStyle(.secondary)
                    .help(button.tooltip(hint: button.hint(in: hints)))
                    .accessibilityLabel(button.accessibilityLabel)
                }
                Spacer(minLength: 0)
            }
        }
        .leoSidebarHeaderFrame(.buttonBar)
    }
}
