import Foundation

/// How a machine's stats are drawn (Settings > "Stats style"). A per-device
/// setting, shared by the Mac and iOS apps.
public enum LeoStatsStyle: String, CaseIterable, Sendable {
    case capsules
    case bars
    case rings
    case numbers
    case off

    public static let `default` = LeoStatsStyle.capsules

    /// Reads the persisted raw value; absent or unknown gives the default.
    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .default
    }

    /// `.off` draws no meters, and the app stops polling stats.
    public var showsMeters: Bool { self != .off }
}
