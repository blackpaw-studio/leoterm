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

    private static let contentHeight: CGFloat = 280

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
            LeoPluginSlotHostRepresentable(key: session.key, surface: session.surface, takesFocus: true)
                .frame(height: Self.contentHeight)
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
