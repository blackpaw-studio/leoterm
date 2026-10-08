import SwiftUI

/// The prompt box and its verbs (B-262), under the terminal splits. Shown
/// for an agent row on a daemon that advertised `agent_control`; the verbs
/// that can't act say why in the field's placeholder, and feedback floats
/// over the terminal's bottom edge so the bar's height never changes (a
/// resize would reflow tmux).
struct LeoAgentControlBar: View {
    let row: LeoAgentRow
    let availability: LeoAgentControlAvailability
    @ObservedObject var control: LeoAgentControlModel
    let focusRequest: Int
    let handle: LeoControlPromptFieldHandle
    let clear: () -> Void

    static let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            LeoControlPromptField(
                text: Binding(get: { control.draft(for: row.id) }, set: { control.setDraft($0, for: row.id) }),
                placeholder: availability.reason ?? "Message \(row.name)",
                isEnabled: availability.canCompose,
                handle: handle,
                onSubmit: send
            )
            sendButton
            symbolButton("stop.circle", "Interrupt", "Interrupt \(row.name) (⌃⌘.)", availability.canInterrupt) {
                Task { await control.interrupt(row) }
            }
            symbolButton("arrow.down.right.and.arrow.up.left", "Compact", "Compact \(row.name)’s context (⌃⌘K)", availability.canCompact) {
                Task { await control.compact(row) }
            }
            symbolButton("eraser", "Clear", "Clear \(row.name)’s conversation… (⌃⇧⌘K)", availability.canClear, action: clear)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .top) { feedbackBanner.alignmentGuide(.top) { $0[.bottom] } }
        .onChange(of: focusRequest) { _ in handle.focus() }
    }

    private var sendButton: some View {
        Button(action: send) {
            if control.inFlight[row.id] == .message {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.up.circle.fill").imageScale(.large)
            }
        }
        .buttonStyle(.borderless)
        .disabled(!availability.canSend || !control.canSendDraft(for: row.id))
        .help("Send to \(row.name) (Return)")
        .accessibilityLabel("Send")
    }

    private func send() {
        guard availability.canSend, control.canSendDraft(for: row.id) else { return }
        Task { await control.send(row) }
    }

    private func symbolButton(_ symbol: String, _ label: String, _ help: String, _ isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).imageScale(.large) }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .help(help)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var feedbackBanner: some View {
        let isDenied = control.deniedHosts.contains(row.host)
        if let line = control.feedback[row.id] ?? (isDenied ? .error(LeoAgentControlAvailability.deniedMessage) : nil) {
            HStack(spacing: 8) {
                Image(systemName: symbol(for: line)).foregroundStyle(.secondary)
                Text(message(of: line)).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true).help(message(of: line))
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

    private func symbol(for feedback: LeoControlFeedback) -> String {
        switch feedback {
        case .error: "xmark.octagon"
        case .notice: "clock"
        }
    }

    private func message(of feedback: LeoControlFeedback) -> String {
        switch feedback {
        case .error(let text), .notice(let text): text
        }
    }
}

/// Observes what decides whether the bar shows and which row it targets,
/// then hosts it. Nothing here when a shell row is selected, nothing is
/// selected, or the daemon doesn't advertise control.
struct LeoAgentControlBarHost: View {
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var control: LeoAgentControlModel
    @ObservedObject var terminals: LeoWindowTerminals
    @ObservedObject var session: LeoWindowSession
    let handle: LeoControlPromptFieldHandle

    var body: some View {
        let row = terminals.selection == nil ? model.actionableSelection : nil
        let availability = LeoAgentControlAvailability(
            row: row, features: model.daemonFeatures, deniedHosts: control.deniedHosts, inFlight: row.flatMap { control.inFlight[$0.id] }
        )
        if let row, availability.isOffered {
            LeoAgentControlBar(
                row: row, availability: availability, control: control, focusRequest: session.controlFocusRequest, handle: handle,
                clear: { Task { await control.clear(row, in: handle.window) } }
            )
        }
    }
}
