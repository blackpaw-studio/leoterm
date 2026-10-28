import Foundation
import LeoKit

/// What an agent's Move menu offers on its daemon (B-324).
public enum MoveAvailability: Equatable, Sendable {
    /// The daemon lacks `agent_move`: no move items at all.
    case unsupported
    /// Duplicate only: the daemon's host list is not read yet, could not be
    /// read, or names no other machine.
    case duplicateOnly
    /// Move To and Copy To these hosts, and Duplicate.
    case hosts([String])

    public init(supportsMove: Bool, destinations: LeoMoveDestinations?) {
        guard supportsMove else {
            self = .unsupported
            return
        }
        if case .hosts(let hosts)? = destinations, !hosts.isEmpty {
            self = .hosts(hosts)
        } else {
            self = .duplicateOnly
        }
    }

    public var offersDuplicate: Bool { self != .unsupported }

    public var hosts: [String] {
        if case .hosts(let hosts) = self { hosts } else { [] }
    }
}
