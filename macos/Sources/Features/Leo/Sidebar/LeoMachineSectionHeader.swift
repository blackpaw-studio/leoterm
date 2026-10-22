import SwiftUI
import LeoKit

/// What a machine header's context menu does.
struct LeoMachineHeaderActions {
    let toggle: () -> Void
    let newAgentHere: () -> Void
    let reconnect: () -> Void
    let editMachine: () -> Void
    let disable: () -> Void
}

/// A machine's section header: a chevron, the status dot and name, the
/// meters in the chosen style and the agent count. Capsules and Rings
/// share the one row; Bars and Numbers add a second.
struct LeoMachineSectionHeader: View {
    let host: LeoHostID
    let presentation: LeoMachineHeaderPresentation
    let style: LeoStatsStyle
    let actions: LeoMachineHeaderActions

    private static let rowHeight: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                titleButton
                Spacer(minLength: 4)
                LeoMachineMeterCluster(meters: presentation.meters, style: style)
                if let count = presentation.count {
                    Text("\(count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(presentation.isAlertCount ? AnyShapeStyle(LeoTint.orange.color) : AnyShapeStyle(.tertiary))
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: Self.rowHeight)
            LeoMachineMeterRow(meters: presentation.meters, style: style)
                .padding(.leading, 22)
        }
        .textCase(nil)
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
    }

    private var titleButton: some View {
        Button(action: actions.toggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(presentation.isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 7)
                    .accessibilityHidden(true)
                Circle().fill(dotColor).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(presentation.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(presentation.isDimmed ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!presentation.canToggleCollapse)
        .help(presentation.nameTooltip ?? "")
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.isCollapsed ? "Collapsed" : "Expanded")
    }

    private var dotColor: Color {
        switch presentation.dot {
        case .connected: LeoTint.green.color
        case .connecting: LeoTint.orange.color
        case .offline: LeoTint.red.color
        }
    }

    @ViewBuilder private var menu: some View {
        Button("New Agent Here…", action: actions.newAgentHere).disabled(!presentation.canNewAgentHere)
        Button("Reconnect", action: actions.reconnect).disabled(!presentation.canReconnect)
        if host != .local {
            Divider()
            Button("Edit Machine…", action: actions.editMachine)
            Button("Disable", action: actions.disable)
        }
    }
}

/// An offline machine's card: why, and the ways back (Reconnect, Open SSH
/// when its failure has a hint, Start daemon for This Mac).
struct LeoMachineOfflineCard: View {
    let presentation: LeoMachineHeaderPresentation
    let failureHint: LeoConnectionFailureHint?
    let reconnect: () -> Void
    let openSSH: (String) -> Void
    /// Only This Mac has a daemon the app can start.
    let startDaemon: (title: String, perform: () -> Void)?

    /// The configured target's hint, sanitized like the reason (B-020).
    private var hintText: String? {
        failureHint.flatMap { LeoConnectionFailurePanel(message: "", hint: $0.hint).hint }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(presentation.isRetrying ? "Reconnecting…" : "Connection failed")
                .font(.callout.weight(.semibold))
                .foregroundStyle(presentation.isRetrying ? AnyShapeStyle(.secondary) : AnyShapeStyle(LeoTint.red.color))
            if let reason = presentation.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .help(reason)
                    .textSelection(.enabled)
            }
            if let hint = hintText {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if presentation.isRetrying {
                    ProgressView().controlSize(.small).accessibilityLabel("Reconnecting")
                }
                if presentation.showsReconnectButton {
                    Button("Reconnect", action: reconnect).controlSize(.small)
                }
                if let ssh = failureHint?.sshTarget {
                    Button("Open SSH") { openSSH(ssh) }.controlSize(.small)
                }
                if let startDaemon {
                    Button(startDaemon.title, action: startDaemon.perform).controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(LeoTint.red.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(LeoTint.red.color.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentation.name) is offline")
    }
}
