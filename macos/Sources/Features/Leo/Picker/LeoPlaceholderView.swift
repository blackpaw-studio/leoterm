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
                chooseAgentButton
                    .disabled(!chooseAgent.isEnabled)
                    .help(chooseAgent.help)
                Button("Show Terminal Drawer", action: toggleDrawer)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    /// A disabled `.borderedProminent` keeps nearly its full accent fill in
    /// dark mode, so it still reads as the thing to press. Prominence is
    /// for the one action available; while there isn't one, the button is
    /// a plain bordered one and gets the familiar greyed look.
    @ViewBuilder private var chooseAgentButton: some View {
        let button = Button("Choose Agent…", action: openPicker)
        if chooseAgent.isProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
