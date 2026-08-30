import SwiftUI

/// Activity/attention status of a grid cell, derived from cell signals.
/// Distinct from `AgentStatus` (daemon lifecycle running/stopped) — this is the
/// Phase 5 status-language concept (spec §5.3) shown as a dot + border.
enum CellStatus: Equatable, Sendable {
    /// Output actively flowing. NOTE: not derived in v1 (deferred); reserved.
    case working
    /// Quiet, nothing happening. Default for a live cell.
    case idle
    /// Agent is waiting on the user (a bell rang). Amber, pulsing.
    case needsYou
    /// Process error or exit (daemon lifecycle stopped). Red.
    case error

    /// Dot color for this status.
    var color: Color {
        switch self {
        case .working: return LeoPalette.working
        case .idle: return LeoPalette.idle
        case .needsYou: return LeoPalette.needsYou
        case .error: return LeoPalette.error
        }
    }

    /// Whether the dot/border should pulse to draw attention.
    var isPulsing: Bool { self == .needsYou }

    /// Whether this status warrants a glowing cell border.
    var hasGlow: Bool { self == .needsYou }

    /// Whether the dot indicator should be rendered. Idle uses absence as its
    /// visual signal — no dot means "nothing happening".
    var isVisible: Bool {
        switch self {
        case .idle: return false
        case .working, .needsYou, .error: return true
        }
    }

    /// Short status word suitable for appending to a cell's identity label
    /// (e.g. "needs you", "stopped"). `nil` for statuses not worth calling
    /// out inline (idle/working are the unremarkable default).
    var statusWord: String? {
        switch self {
        case .working, .idle: return nil
        case .needsYou: return "needs you"
        case .error: return "stopped"
        }
    }

    /// Human-readable description for VoiceOver, read alongside the cell it
    /// annotates.
    var accessibilityDescription: String {
        switch self {
        case .working: return "Working"
        case .idle: return "Idle"
        case .needsYou: return "Needs your attention"
        case .error: return "Stopped with error"
        }
    }
}

/// Pure derivation of a cell's status from its signals. Priority:
/// error (lifecycle stopped) > needsYou (bell, agents only) > idle.
/// `working` is deferred in v1 and never produced here.
/// - Parameters:
///   - isAgent: true for `.agent` cells; false for plain `.pty` cells.
///   - hasBell: the backing surface's current bell flag.
///   - lifecycle: the daemon-reported lifecycle, or nil for pty cells.
func deriveCellStatus(
    isAgent: Bool,
    hasBell: Bool,
    lifecycle: AgentStatus?
) -> CellStatus {
    if isAgent, lifecycle == .stopped { return .error }
    if isAgent, hasBell { return .needsYou }
    return .idle
}
