import SwiftUI

/// Maps every agent/host status value the sidebar shows into a presentation
/// triple: an SF Symbol name (so the *shape*, not just the color, conveys the
/// state), a semantic system color (so dark mode, Increase Contrast, and
/// color filters all work), and an accessibility label.
///
/// This is the single source of truth for that mapping -- both the agent row
/// (`LeoAgentRow.swift`) and the host picker (`LeoSidebarView.swift`) read
/// from here instead of each encoding status with hard-coded colors or typed
/// glyph characters.
enum LeoStatusPresentation {
    struct Presentation: Equatable {
        let symbolName: String
        let color: Color
        let accessibilityLabel: String
    }

    /// The 7x7 activity dot on an agent row.
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

    /// The status badge ("running" / "starting" / "stopped" / ...) on an
    /// agent row.
    static func agentStatus(_ status: LeoAgentStatus) -> Presentation {
        switch status {
        case .running:
            return Presentation(
                symbolName: "circle.fill",
                color: Color(nsColor: .systemGreen),
                accessibilityLabel: "Running"
            )
        case .starting:
            return Presentation(
                symbolName: "circle.fill",
                color: Color(nsColor: .systemOrange),
                accessibilityLabel: "Starting"
            )
        case .stopped:
            return Presentation(
                symbolName: "circle",
                color: Color.secondary,
                accessibilityLabel: "Stopped"
            )
        case .unknown(let raw):
            return Presentation(
                symbolName: "questionmark.circle",
                color: Color.secondary,
                accessibilityLabel: "Status: \(raw)"
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
