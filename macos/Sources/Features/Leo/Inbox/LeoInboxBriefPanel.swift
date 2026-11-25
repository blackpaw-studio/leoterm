import LeoKit
import SwiftUI

/// The agent's own summary of its work, under an inbox item: goal, status,
/// decisions and open items. A stale brief shows its age in secondary color.
struct LeoInboxBriefPanel: View {
    let brief: LeoAgentBriefPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Brief").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let age = brief.ageText {
                    Text("· updated \(age)").font(.caption).foregroundStyle(brief.isStale ? .secondary : .tertiary)
                }
            }
            if let goal = brief.goal {
                Text(goal).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let status = brief.status {
                Text(status).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            bullets("Decisions", brief.decisions)
            bullets("Open", brief.open)
        }
        .textSelection(.enabled)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .accessibilityIdentifier("inbox.brief")
    }

    @ViewBuilder private func bullets(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(item).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
