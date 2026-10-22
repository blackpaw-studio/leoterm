import Foundation

/// One CPU/memory/disk sample of a machine, as the sidebar header draws it.
/// TODO(S1): replace with LeoKit's `LeoMachineStats` (whose sections are
/// each nullable) once S1 merges; `receiveStats(_:for:)` and the header
/// presentation only need this shape.
struct LeoSidebarMachineStats: Equatable, Sendable {
    let sampledAt: Date
    /// Nil on a daemon's first sample.
    let cpuPercent: Double?
    let memoryUsedBytes: Int
    let memoryTotalBytes: Int
    let diskUsedBytes: Int
    let diskTotalBytes: Int
}
