import AppKit
import SwiftUI

/// B-057: a row in the sidebar's Terminals section -- a plain shell in this
/// window, titled by its terminal. A click (or VoiceOver's press) shows it
/// in the window's content area, like an agent row's; the arrow keys only
/// select it. A title another row already shows carries a quiet
/// secondary suffix, "(2)", that stays visible however the title
/// truncates (B-068).
struct LeoTerminalRowView: View {
    let label: LeoTerminalRowLabel
    let activate: () -> Void

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
                    .help(label.text)
                if let suffix = label.suffix {
                    Text(suffix)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        // Every click inside the row is a row click, read from the mouse
        // events themselves (see `LeoRowClickCatcher`, B-048/B-049).
        .background(LeoRowClickCatcher(identity: label.id) { _, clickCount in
            guard clickCount == 1 else { return }
            activate()
        }.accessibilityHidden(true))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label.text), terminal")
        .accessibilityAction { activate() }
        .accessibilityAction(named: LeoRowAccessibility.pressName) { activate() }
    }
}
