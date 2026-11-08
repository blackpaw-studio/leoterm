import SwiftUI

/// The result of an agent-control verb (Interrupt, Compact, Clear, a denied
/// host), floated over the detail column's bottom edge. It is an overlay, never
/// a row: the column's height must not change, because a resize reflows tmux.
struct LeoControlFeedbackBanner: View {
    let row: LeoAgentRow
    @ObservedObject var control: LeoAgentControlModel

    var body: some View {
        let isDenied = control.deniedHosts.contains(row.host)
        if let line = control.feedback[row.id] ?? (isDenied ? .error(LeoAgentControlAvailability.deniedMessage) : nil) {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(for: line)).foregroundStyle(.secondary)
                Text(Self.message(of: line)).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(Self.message(of: line))
                Spacer(minLength: 8)
                if isDenied {
                    Button("Retry") { control.retryAfterDenial(host: row.host) }.controlSize(.small)
                } else {
                    Button { control.dismissFeedback(for: row.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                        .accessibilityLabel("Dismiss")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
        }
    }

    private static func symbol(for feedback: LeoControlFeedback) -> String {
        switch feedback {
        case .error: "xmark.octagon"
        case .notice: "clock"
        }
    }

    private static func message(of feedback: LeoControlFeedback) -> String {
        switch feedback {
        case .error(let text), .notice(let text): text
        }
    }
}
