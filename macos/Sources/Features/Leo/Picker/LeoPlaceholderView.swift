import SwiftUI

/// Shown in place of the terminal split tree when a Leo-managed window's
/// `surfaceTree` is empty (a brand-new window, or the last surface in a
/// placeholder window closed). Task 3 replaces the copy/layout with the
/// full palette-launch experience; this is deliberately minimal.
struct LeoPlaceholderView: View {
    let openPicker: () -> Void
    let toggleDrawer: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Pick an agent · ⌘T")
                .font(.headline)
                .foregroundStyle(.secondary)
            Button("Pick an Agent…", action: openPicker)
                .keyboardShortcut("t", modifiers: .command)
            Button("Toggle Terminal Drawer", action: toggleDrawer)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
