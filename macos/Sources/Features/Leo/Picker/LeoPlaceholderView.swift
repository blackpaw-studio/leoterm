import SwiftUI

/// Shown in place of the terminal split tree when a Leo-managed window's
/// `surfaceTree` is empty (a brand-new window, or the last surface in a
/// placeholder window closed).
struct LeoPlaceholderView: View {
    let openPicker: () -> Void
    let toggleDrawer: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Pick an agent")
                    .font(.title3.weight(.semibold))
                Text("⌘T opens the picker · terminal drawer via the menu")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Pick an Agent…", action: openPicker)
                    .keyboardShortcut("t", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                Button("Toggle Terminal Drawer", action: toggleDrawer)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
