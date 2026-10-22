import Foundation

/// One `GET /machine` (socket) or `/api/v1/machine` (web) sample of a
/// machine's load (leo >= 0.57, `machine_stats`). Each section is `nil` when
/// the daemon's probe for it failed, so one broken probe blanks one meter.
public struct LeoMachineStats: Equatable, Sendable {
    /// The daemon's error code for a 503: the machine has no stats to give.
    public static let unavailableCode = "machine_stats_unavailable"

    public struct CPU: Equatable, Sendable {
        /// Whole-machine CPU since the previous sample; `nil` on the first.
        public let percent: Double?
        public let cores: Int

        public init(percent: Double?, cores: Int) {
            self.percent = percent
            self.cores = cores
        }

        public var fraction: Double? { percent.map { Self.clamp($0 / 100) } }

        private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
    }

    public struct Memory: Equatable, Sendable {
        public let usedBytes: Int64
        public let totalBytes: Int64

        public init(usedBytes: Int64, totalBytes: Int64) {
            self.usedBytes = usedBytes
            self.totalBytes = totalBytes
        }

        public var fraction: Double? { LeoMachineStats.fraction(used: usedBytes, total: totalBytes) }
    }

    /// The volume holding the daemon's state directory.
    public struct Disk: Equatable, Sendable {
        public let path: String
        public let usedBytes: Int64
        public let totalBytes: Int64

        public init(path: String, usedBytes: Int64, totalBytes: Int64) {
            self.path = path
            self.usedBytes = usedBytes
            self.totalBytes = totalBytes
        }

        public var fraction: Double? { LeoMachineStats.fraction(used: usedBytes, total: totalBytes) }
    }

    public let sampledAt: Date
    public let cpu: CPU?
    public let memory: Memory?
    public let disk: Disk?

    public init(sampledAt: Date, cpu: CPU?, memory: Memory?, disk: Disk?) {
        self.sampledAt = sampledAt
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
    }

    /// Used share of a total, clamped to 0...1; `nil` when the total is unknown.
    fileprivate static func fraction(used: Int64, total: Int64) -> Double? {
        guard total > 0 else { return nil }
        return min(max(Double(used) / Double(total), 0), 1)
    }
}

extension LeoMachineStats: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sampledAt = "sampled_at"
        case cpu, memory, disk
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampledAt = try container.decode(LeoChatTimestamp.self, forKey: .sampledAt).date
        cpu = try container.decodeIfPresent(CPU.self, forKey: .cpu)
        memory = try container.decodeIfPresent(Memory.self, forKey: .memory)
        disk = try container.decodeIfPresent(Disk.self, forKey: .disk)
    }
}

extension LeoMachineStats.CPU: Decodable {}

extension LeoMachineStats.Memory: Decodable {
    private enum CodingKeys: String, CodingKey {
        case usedBytes = "used_bytes"
        case totalBytes = "total_bytes"
    }
}

extension LeoMachineStats.Disk: Decodable {
    private enum CodingKeys: String, CodingKey {
        case path
        case usedBytes = "used_bytes"
        case totalBytes = "total_bytes"
    }
}
