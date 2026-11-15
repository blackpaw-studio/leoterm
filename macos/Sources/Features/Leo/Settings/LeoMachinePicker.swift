import LeoKit
import SwiftUI

/// The Settings toolbar's machine picker: which daemon the config panes
/// edit. Shown only on a config tab; Machines edits the list itself.
struct LeoMachinePicker: View {
    @ObservedObject var target: LeoSettingsTargetModel
    /// Observed so the list follows machines being added or removed.
    @ObservedObject var registry: LeoMachineRegistry

    var body: some View {
        if target.selectedTab.usesMachineTarget {
            HStack(spacing: 6) {
                LeoStatusDot(status: registry.status(for: target.selectedHost))
                Picker("Machine", selection: Binding(get: { target.selectedHost }, set: { _ = target.requestSwitch(to: $0) })) {
                    ForEach(registry.machines, id: \.self) { host in
                        Text(SpawnMachineOption.title(for: host)).tag(host)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Machine to edit")
            }
            .padding(.horizontal, 6)
        }
    }
}
