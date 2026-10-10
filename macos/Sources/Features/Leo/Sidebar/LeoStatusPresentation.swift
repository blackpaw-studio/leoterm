import SwiftUI

/// Maps every agent/host status value the sidebar shows into a presentation
/// triple: an SF Symbol name (so the *shape*, not just the color, conveys the
/// state), a semantic system color (so dark mode, Increase Contrast, and
/// color filters all work), and an accessibility label.
///
/// This is the single source of truth for that mapping -- the agent palette,
/// the host picker (`LeoSidebarView.swift`) and the attention reasons read
/// from here instead of each encoding status with hard-coded colors or typed
/// glyph characters. The agent row's own state symbol lives in `LeoAgentRowState`.
enum LeoStatusPresentation {
    struct Presentation: Equatable {
        let symbolName: String
        let color: Color
        let accessibilityLabel: String
    }

    /// The activity dot in the agent palette.
    ///
    /// `.unknown` means "no activity data yet" (the row hasn't received a
    /// feed update), not an error, so it intentionally has no symbol here --
    /// the row keeps it hidden rather than showing a warning for a
    /// not-yet-known state.
    static func activity(_ activity: LeoAgentRow.Activity) -> Presentation {
        switch activity {
        case .working:
            return Presentation(
                symbolName: "circle.fill",
                color: Color(nsColor: .systemGreen),
                accessibilityLabel: "Working"
            )
        case .idle:
            return Presentation(
                symbolName: "circle",
                color: Color(nsColor: .systemGray),
                accessibilityLabel: "Idle"
            )
        case .unknown:
            return Presentation(
                symbolName: "circle.dotted",
                color: Color.secondary,
                accessibilityLabel: "Activity unknown"
            )
        }
    }

    /// What a needs_input state says when the daemon gave a reason (B-258).
    /// Every string derives from the kind and the (sanitized) tool; `detail`
    /// appears only in the tooltip, never in the notification.
    struct ReasonPresentation: Equatable {
        let symbolName: String
        let tooltip: String
        /// VoiceOver text ("Needs Permission, Bash").
        let accessibilityLabel: String
        /// The notification body.
        let notificationBody: String
    }

    static func attentionReason(_ reason: LeoAttentionReason) -> ReasonPresentation {
        let tool = reason.tool
        switch reason.kind {
        case .permission:
            return ReasonPresentation(
                symbolName: "hand.raised",
                tooltip: [tool.map { "Needs permission to use \($0)" } ?? "Needs permission", reason.detail].compactMap { $0 }.joined(separator: ": "),
                accessibilityLabel: ["Needs Permission", tool].compactMap { $0 }.joined(separator: ", "),
                notificationBody: tool.map { "Needs permission to use \($0)" } ?? "Needs permission"
            )
        case .question:
            return ReasonPresentation(
                symbolName: "questionmark.bubble",
                tooltip: ["Asking you a question", reason.detail].compactMap { $0 }.joined(separator: ": "),
                accessibilityLabel: "Asking a Question",
                notificationBody: "Has a question for you"
            )
        case .elicitation:
            let request = tool.map { "Requesting input from \($0)" } ?? "Requesting input"
            return ReasonPresentation(
                symbolName: "list.bullet.rectangle",
                tooltip: [request, reason.detail].compactMap { $0 }.joined(separator: ": "),
                accessibilityLabel: ["Requesting Input", tool].compactMap { $0 }.joined(separator: ", "),
                notificationBody: "Requesting input"
            )
        }
    }

    /// The connection glyph shown next to a host in the sidebar's host
    /// picker menu. Only the *selected* host has a live connection state;
    /// every other configured host (and localhost when it isn't selected)
    /// shows a neutral glyph, so `state` is `nil` in that case.
    static func hostConnection(isSelected: Bool, state: LeoHostConnectionState?) -> Presentation {
        guard isSelected, let state else {
            return Presentation(
                symbolName: "circle",
                color: Color.secondary,
                accessibilityLabel: "Not connected"
            )
        }

        switch state {
        case .connected:
            return Presentation(
                symbolName: "circle.fill",
                color: Color(nsColor: .systemGreen),
                accessibilityLabel: "Connected"
            )
        case .connecting:
            return Presentation(
                symbolName: "circle.dotted",
                color: Color.secondary,
                accessibilityLabel: "Connecting"
            )
        case .failed:
            return Presentation(
                symbolName: "exclamationmark.triangle.fill",
                color: Color(nsColor: .systemOrange),
                accessibilityLabel: "Connection failed"
            )
        }
    }
}
