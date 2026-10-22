import Foundation
import LeoKit

/// One meter of a machine's stats as the Machines list draws it.
public struct MachineMeter: Equatable, Identifiable, Sendable {
    public enum Kind: CaseIterable, Sendable {
        case cpu
        case memory
        case disk
    }

    public let kind: Kind
    /// 0...1; `nil` when the daemon has no figure for it (first CPU sample,
    /// failed probe).
    public let fraction: Double?

    public var id: Kind { kind }
    public var level: LeoMeterLevel { .level(fraction: fraction) }

    /// "41%", or an em dash with no figure.
    public var percentText: String {
        fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

extension LeoMachineStats {
    /// CPU, memory and disk in the order every style draws them.
    public var meters: [MachineMeter] {
        [
            MachineMeter(kind: .cpu, fraction: cpu?.fraction),
            MachineMeter(kind: .memory, fraction: memory?.fraction),
            MachineMeter(kind: .disk, fraction: disk?.fraction),
        ]
    }
}
