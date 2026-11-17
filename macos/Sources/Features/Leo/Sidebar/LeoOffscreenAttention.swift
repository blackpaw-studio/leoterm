import Foundation
import LeoKit

/// B-413 (P2): which agents that need the user are scrolled out of the
/// sidebar, and what the edge indicator says about them. Pure: the list's
/// visible rows and each agent's table-row index come in as values.
///
/// Only the row's own displayed state counts: Needs You, Error (a failed
/// action the row draws red included) or an unread chat badge. Working,
/// finished and idle rows never do, and nothing is invented that the row
/// itself doesn't already show.
enum LeoOffscreenAttention {
    /// Why a row is worth an indicator, most urgent first.
    enum Kind: Int, Equatable, Comparable {
        case needsYou, error, unread

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One listed agent row that needs the user.
    struct Candidate: Equatable, Identifiable {
        let id: LeoAgentRow.ID
        let name: String
        /// Its index among the table's rows.
        let tableRow: Int
        let kind: Kind
        let unreadCount: Int
    }

    /// The nearest such row off each edge; each direction stands alone.
    struct Targets: Equatable {
        var above: Candidate?
        var below: Candidate?

        static let none = Targets()
    }

    /// Why `row` needs the user, nil when it doesn't. `unread` is the
    /// row's unread chat count; `error` its last failed-action message.
    static func kind(of row: LeoAgentRow, error: String?, unread: Int) -> Kind? {
        switch LeoAgentRowState(row: row, error: error).state {
        case .needsYou: .needsYou
        case .error: .error
        default: unread > 0 ? .unread : nil
        }
    }

    /// The candidates above and below `visibleRows`: above is the one
    /// nearest the top edge (highest index above the range), below the one
    /// nearest the bottom edge (lowest index below it). A nil range (the
    /// list has not been measured) shows nothing.
    static func targets(of candidates: [Candidate], visibleRows: ClosedRange<Int>?) -> Targets {
        guard let visibleRows else { return .none }
        return Targets(
            above: candidates.filter { $0.tableRow < visibleRows.lowerBound }.max { $0.tableRow < $1.tableRow },
            below: candidates.filter { $0.tableRow > visibleRows.upperBound }.min { $0.tableRow < $1.tableRow }
        )
    }

    enum Edge: Equatable {
        case top, bottom

        var identifier: String { self == .top ? "leo.sidebar.offscreenAttention.top" : "leo.sidebar.offscreenAttention.bottom" }
        var symbolName: String { self == .top ? "arrow.up" : "arrow.down" }
        var directionWord: String { self == .top ? "up" : "down" }
    }

    /// What the indicator at `edge` shows for `target`, given how many
    /// candidates lie off that edge.
    struct Presentation: Equatable {
        let edge: Edge
        let target: Candidate
        /// "Needs you", or "3 need you" when several lie off the edge.
        let text: String
        /// "Scroll up to alpha, needs you".
        let accessibilityLabel: String
        let hint = "Scrolls the list to this agent"
    }

    static func presentation(edge: Edge, target: Candidate, offscreenCount: Int) -> Presentation {
        Presentation(
            edge: edge, target: target,
            text: offscreenCount > 1 ? "\(offscreenCount) need you" : "Needs you",
            accessibilityLabel: "Scroll \(edge.directionWord) to \(target.name), \(spokenReason(of: target))"
        )
    }

    private static func spokenReason(of candidate: Candidate) -> String {
        switch candidate.kind {
        case .needsYou: "needs you"
        case .error: "error"
        case .unread: candidate.unreadCount == 1 ? "1 unread message" : "\(candidate.unreadCount) unread messages"
        }
    }

    /// How many candidates lie off each edge, for the "N need you" text.
    static func offscreenCounts(of candidates: [Candidate], visibleRows: ClosedRange<Int>?) -> (above: Int, below: Int) {
        guard let visibleRows else { return (0, 0) }
        return (
            candidates.filter { $0.tableRow < visibleRows.lowerBound }.count,
            candidates.filter { $0.tableRow > visibleRows.upperBound }.count
        )
    }
}
