import SwiftUI

/// B-331: on a collapsed agent row, how many of its dispatches are running,
/// as a quiet blue capsule (an attention color would claim the agent needs
/// something). Nothing at 0.
struct LeoRunningSubagentsBadge: View {
    let count: Int
    var isOnSelection = false

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isOnSelection ? Color.white : Color.blue)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(isOnSelection ? Color.white.opacity(0.25) : Color.blue.opacity(0.15)))
                .fixedSize()
                .help(count == 1 ? "1 subagent running" : "\(count) subagents running")
                .accessibilityLabel("\(count) subagent\(count == 1 ? "" : "s") running")
        }
    }
}
