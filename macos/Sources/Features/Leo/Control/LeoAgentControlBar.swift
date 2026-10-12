import AppKit
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
    let layout: LeoChatLayout
    let choose: (LeoAgentViewChoice) -> Void
    /// Agents ▸ Message Agent while the prompt field is hidden.
    let focusChat: () -> Void

    static let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 8) {
            // Chat in the terminal's place: its composer is the only input.
            if layout.isTerminalVisible {
                LeoControlPromptField(
                    text: Binding(get: { control.draft(for: row.id) }, set: { control.setDraft($0, for: row.id) }),
                    placeholder: availability.reason ?? "Message \(row.name)",
                    isEnabled: availability.canCompose,
                    handle: handle,
                    onSubmit: send
                )
                sendButton
            } else {
                Spacer(minLength: 0)
            }
            symbolButton("stop.circle", "Interrupt", "Interrupt \(row.name) (⌃⌘.)", availability.canInterrupt) {
                Task { await control.interrupt(row) }
            }
            symbolButton("arrow.down.right.and.arrow.up.left", "Compact", "Compact \(row.name)’s context (⌃⌘K)", availability.canCompact) {
                Task { await control.compact(row) }
            }
            symbolButton("eraser", "Clear", "Clear \(row.name)’s conversation… (⌃⇧⌘K)", availability.canClear, action: clear)
            Divider().frame(height: 18)
            LeoAgentViewSwitch(agentName: row.name, active: layout.activeSegments, choose: choose)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .top) { feedbackBanner.alignmentGuide(.top) { $0[.bottom] } }
        .onChange(of: focusRequest) { _ in layout.isTerminalVisible ? handle.focus() : focusChat() }
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
/// then hosts it. Nothing here when a shell row is selected or nothing is
/// selected; just the Terminal | Chat switch when the daemon doesn't
/// advertise control.
struct LeoAgentControlBarHost: View {
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var control: LeoAgentControlModel
    @ObservedObject var terminals: LeoWindowTerminals
    @ObservedObject var session: LeoWindowSession
    let handle: LeoControlPromptFieldHandle
    /// The content area's width, which decides how chat is laid out.
    let contentWidth: CGFloat

    var body: some View {
        let row = terminals.selection == nil ? model.actionableSelection : nil
        let layout = session.chatLayout(for: row, contentWidth: contentWidth)
        let availability = LeoAgentControlAvailability(
            row: row, features: model.daemonFeatures, deniedHosts: control.deniedHosts, inFlight: row.flatMap { control.inFlight[$0.id] }
        )
        switch LeoAgentControlBarContent(row: row, availability: availability) {
        case .none:
            EmptyView()
        case .chatToggleOnly:
            // No agent control on this daemon: chat stays reachable.
            if let row {
                HStack {
                    Spacer()
                    LeoAgentViewSwitch(
                        agentName: row.name, active: layout.activeSegments, choose: { session.choose($0, for: row.id) }
                    )
                }
                .padding(.horizontal, 10)
                .frame(height: LeoAgentControlBar.height)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        case .full:
            if let row { fullBar(row, availability, layout) }
        }
    }

    private func fullBar(_ row: LeoAgentRow, _ availability: LeoAgentControlAvailability, _ layout: LeoChatLayout) -> some View {
        LeoAgentControlBar(
            row: row, availability: availability, control: control, focusRequest: session.controlFocusRequest, handle: handle,
            clear: { Task { await control.clear(row, in: handle.window ?? session.window) } },
            layout: layout,
            choose: { session.choose($0, for: row.id) },
            focusChat: session.requestChatFocus
        )
    }
}

/// The Terminal | Chat switch. Side by side, both segments are lit;
/// clicking one shows that alone (Chat alone still sits beside the terminal
/// when the window is wide enough).
struct LeoAgentViewSwitch: NSViewRepresentable {
    let agentName: String
    let active: Set<LeoAgentViewChoice>
    let choose: (LeoAgentViewChoice) -> Void

    private static let segments: [(choice: LeoAgentViewChoice, label: String)] = [(.terminal, "Terminal"), (.chat, "Chat")]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: Self.segments.map(\.label), trackingMode: .selectAny,
            target: context.coordinator, action: #selector(Coordinator.clicked(_:))
        )
        control.segmentStyle = .rounded
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setAccessibilityLabel("View")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (index, segment) in Self.segments.enumerated() {
            control.setSelected(active.contains(segment.choice), forSegment: index)
        }
        control.setToolTip("Show \(agentName)’s terminal", forSegment: 0)
        control.setToolTip("Chat with \(agentName)", forSegment: 1)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject {
        var parent: LeoAgentViewSwitch

        init(parent: LeoAgentViewSwitch) { self.parent = parent }

        /// With `.selectAny` a click flips its segment, so the clicked one is
        /// the segment whose state no longer matches what was shown.
        @objc func clicked(_ control: NSSegmentedControl) {
            let segments = LeoAgentViewSwitch.segments
            let clicked = segments.indices.first { control.isSelected(forSegment: $0) != parent.active.contains(segments[$0].choice) }
            for (index, segment) in segments.enumerated() {
                control.setSelected(parent.active.contains(segment.choice), forSegment: index)
            }
            guard let clicked else { return }
            parent.choose(segments[clicked].choice)
        }
    }
}
