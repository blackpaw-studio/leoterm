import SwiftUI

/// Shown in place of the terminal split tree when a Leo-managed window's
/// `surfaceTree` is empty (a brand-new window, or the last surface in a
/// placeholder window closed).
struct LeoPlaceholderView: View {
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var hostSelection: LeoHostSelection
    let openPicker: () -> Void
    let toggleDrawer: () -> Void

    private var chooseAgent: LeoPlaceholderChooseAgent {
        LeoPlaceholderChooseAgent(host: hostSelection.selected, connectivity: model.snapshot.connectivity)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("No Agent Attached")
                    .font(.title3.weight(.semibold))
                Text("Attach to an agent or open a plain shell.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Choose Agent…", action: openPicker)
                    .buttonStyle(.borderedProminent)
                    .disabled(!chooseAgent.isEnabled)
                    .help(chooseAgent.help)
                Button("Show Terminal Drawer", action: toggleDrawer)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
