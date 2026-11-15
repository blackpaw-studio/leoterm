import Foundation

/// How alarming a meter's fill is: drives the meter's colour on every
/// platform.
public enum LeoMeterLevel: Equatable, Sendable {
    case normal
    case warning
    case critical

    public static let warningThreshold = 0.8
    public static let criticalThreshold = 0.9

    /// Below 0.8 is normal, from 0.8 warning, from 0.9 critical. An unknown
    /// fraction (no sample, zero total) reads as normal.
    public static func level(fraction: Double?) -> LeoMeterLevel {
        guard let fraction else { return .normal }
        if fraction >= criticalThreshold { return .critical }
        if fraction >= warningThreshold { return .warning }
        return .normal
    }
}
