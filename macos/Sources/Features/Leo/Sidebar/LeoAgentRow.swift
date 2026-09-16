import AppKit
import SwiftUI

enum LeoAttachActivation {
    enum Source {
        case button
        case rowDoubleClick
        case keyboard
    }

    static func disposition(for modifierFlags: NSEvent.ModifierFlags) -> AttachDisposition {
        modifierFlags.contains(.option) ? .newWindow : .reuseOrTab
    }

    static func activate(
        source _: Source,
        row: LeoAgentRow,
        attach: (LeoAgentRow, AttachDisposition) -> Void
    ) {
        activate(row: row, modifierFlags: NSEvent.modifierFlags, attach: attach)
    }

    static func activate(
        row: LeoAgentRow,
        modifierFlags: NSEvent.ModifierFlags,
        attach: (LeoAgentRow, AttachDisposition) -> Void
    ) {
        attach(row, disposition(for: modifierFlags))
    }
}

struct LeoAgentRowView: View {
    let row: LeoAgentRow
    let isSelected: Bool
    let attach: (LeoAgentRow, AttachDisposition) -> Void

    var body: some View {
        HStack(spacing: 8) {
            activityDot
            rowDetails
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { activate(source: .rowDoubleClick) }
            Button("Attach") { activate(source: .button) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Attach to \(row.name)")
        }
        .contentShape(Rectangle())
    }

    private var rowDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                statusBadge
            }
            if let template = row.template, !template.isEmpty {
                Text(template).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let detail = row.actionDetail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var activityDot: some View {
        switch row.activity {
        case .working:
            Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Working")
        case .idle:
            Circle().fill(.gray).frame(width: 7, height: 7).accessibilityLabel("Idle")
        case .unknown:
            Color.clear.frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }

    private var statusBadge: some View {
        Text(statusText)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.18), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusText: String {
        switch row.status {
        case .running: "running"
        case .starting: "starting"
        case .stopped: "stopped"
        case .unknown: "unknown"
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .running: .green
        case .starting: .orange
        case .stopped: .secondary
        case .unknown: .secondary
        }
    }

    private func activate(source: LeoAttachActivation.Source) {
        LeoAttachActivation.activate(source: source, row: row, attach: attach)
    }
}
