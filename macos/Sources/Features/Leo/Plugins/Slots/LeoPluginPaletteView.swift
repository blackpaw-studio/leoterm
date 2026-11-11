import LeoKit
import SwiftUI

/// The command palette's page for a plugin command: a back row, then the
/// command's view. Same chrome as the palette's own panel. Esc pops a pushed
/// view, and at the root returns to the command list.
struct LeoPluginPaletteView: View {
    @ObservedObject var session: LeoPluginPaletteSession
    let backgroundColor: Color
    /// Back to the command list.
    let showList: () -> Void

    @State private var preferredHeight: CGFloat?

    var body: some View {
        let scheme: ColorScheme = NSColor(backgroundColor).isLightColor ? .light : .dark
        VStack(alignment: .leading, spacing: 0) {
            Button(action: back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                    Text(session.command.title).font(.system(size: 15, weight: .medium))
                    Text(session.command.pluginName).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("esc").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back")
            Divider()
            LeoPluginSlotHostRepresentable(
                key: session.key, surface: session.surface, takesFocus: true,
                onPreferredHeightChange: { preferredHeight = $0 })
                .frame(height: LeoPluginPaletteLayout.height(forContent: preferredHeight))
        }
        .frame(maxWidth: 500)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(backgroundColor).blendMode(.color)
            }
            .compositingGroup()
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75)))
        .shadow(radius: 32, x: 0, y: 12)
        .padding()
        .environment(\.colorScheme, scheme)
    }

    private func back() {
        if session.back() == .atRoot { showList() }
    }
}

/// How tall the palette's plugin pane is: lists keep the standard height, a
/// scrolling view (a form) grows to fit its content, up to a ceiling, and
/// scrolls beyond it.
enum LeoPluginPaletteLayout {
    static let minHeight: CGFloat = 280
    static let maxHeight: CGFloat = 520

    static func height(forContent content: CGFloat?) -> CGFloat {
        guard let content else { return minHeight }
        return min(max(content.rounded(.up), minHeight), maxHeight)
    }
}
