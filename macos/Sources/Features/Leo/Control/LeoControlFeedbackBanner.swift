import SwiftUI

/// Where control feedback shows: over the terminal column while a terminal
/// is visible (an overlay, so the column's height never changes and tmux
/// never reflows), else above the chat composer, which it must not cover.
enum LeoControlFeedbackPlacement: Equatable {
    case overTerminal
    case aboveComposer

    init(layout: LeoChatLayout) {
        self = layout.isTerminalVisible ? .overTerminal : .aboveComposer
    }
}

/// The result of an agent-control verb (Interrupt, Compact, Clear, a denied
/// host), shown per `LeoControlFeedbackPlacement`.
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
