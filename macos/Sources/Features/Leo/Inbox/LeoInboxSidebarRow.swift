import LeoKit
import SwiftUI

/// The pinned Inbox row under the sidebar's search field: an orange count of
/// what needs you, a grey dot when only unread finished work waits, nothing
/// when the inbox is empty (`LeoInboxBadge`).
struct LeoInboxSidebarEntry: View {
    @ObservedObject var inbox: LeoInboxModel
    @ObservedObject var terminals: LeoWindowTerminals
    let select: () -> Void

    var body: some View {
        LeoInboxSidebarRow(badge: inbox.inbox.badge, isSelected: terminals.isInboxSelected, action: select)
    }
}

struct LeoInboxSidebarRow: View {
    let badge: LeoInboxBadge
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .frame(width: 18)
                Text("Inbox")
                    .fontWeight(.medium)
                Spacer(minLength: 4)
                badgeView
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.inbox")
    }

    @ViewBuilder private var badgeView: some View {
        switch badge {
        case .none:
            EmptyView()
        case .dot:
            Circle()
                .fill(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .frame(width: 8, height: 8)
        case .count(let count):
            Text(count > 99 ? "99+" : "\(count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.orange : Color.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(isSelected ? Color.white : Color.orange))
                .fixedSize()
        }
    }

    private var accessibilityLabel: String {
        switch badge {
        case .none: "Inbox"
        case .dot: "Inbox, finished work you haven't seen"
        case .count(let count): "Inbox, \(count) need\(count == 1 ? "s" : "") you"
        }
    }
}
