import AppKit
import SwiftUI

/// B-057: a row in the sidebar's Terminals section -- a plain shell in this
/// window, titled by its terminal. A click (or VoiceOver's press) shows it
/// in the window's content area, like an agent row's; the arrow keys only
/// select it.
struct LeoTerminalRowView: View {
    let row: LeoTerminalRow
    let activate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(row.displayTitle)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.displayTitle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        // Every click inside the row is a row click, read from the mouse
        // events themselves (see `LeoRowClickCatcher`, B-048/B-049).
        .background(LeoRowClickCatcher(identity: row.id) { _, clickCount in
            guard clickCount == 1 else { return }
            activate()
        }.accessibilityHidden(true))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.displayTitle), terminal")
        .accessibilityAction { activate() }
        .accessibilityAction(named: LeoRowAccessibility.pressName) { activate() }
    }
}
