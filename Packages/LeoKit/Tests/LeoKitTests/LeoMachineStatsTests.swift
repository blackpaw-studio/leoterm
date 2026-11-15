import Foundation
import Testing

@testable import LeoKit

struct LeoMachineStatsTests {
    private static let full = #"""
    {"sampled_at":"2026-10-21T12:00:00Z","cpu":{"percent":37.5,"cores":10},
     "memory":{"used_bytes":8000,"total_bytes":16000},
     "disk":{"path":"/Users/evan/.leo","used_bytes":250,"total_bytes":1000}}
    """#

    private static func decode(_ json: String) throws -> LeoMachineStats {
        try JSONDecoder().decode(LeoMachineStats.self, from: Data(json.utf8))
    }

    @Test func decodesTheFullPayload() throws {
        let stats = try Self.decode(Self.full)

        #expect(stats.sampledAt == Date(timeIntervalSince1970: 1_792_584_000))
        #expect(stats.cpu == .init(percent: 37.5, cores: 10))
        #expect(stats.memory == .init(usedBytes: 8000, totalBytes: 16000))
        #expect(stats.disk == .init(path: "/Users/evan/.leo", usedBytes: 250, totalBytes: 1000))
    }

    @Test func firstSampleHasNullCPUPercent() throws {
        let stats = try Self.decode(Self.full.replacingOccurrences(of: "37.5", with: "null"))

        #expect(stats.cpu == .init(percent: nil, cores: 10))
        #expect(stats.cpu?.fraction == nil)
    }

    @Test func eachSectionIsIndependentlyNullable() throws {
        let stats = try Self.decode(#"{"sampled_at":"2026-10-21T12:00:00Z","cpu":null,"memory":null}"#)

        #expect(stats.cpu == nil)
        #expect(stats.memory == nil)
        #expect(stats.disk == nil)
    }

    @Test func readsFractionalSecondTimestamps() throws {
        let stats = try Self.decode(Self.full.replacingOccurrences(of: "12:00:00Z", with: "12:00:00.250Z"))

        #expect(abs(stats.sampledAt.timeIntervalSince1970 - 1_792_584_000.25) < 0.001)
    }

    @Test func ignoresUnknownKeys() throws {
        let stats = try Self.decode(Self.full.replacingOccurrences(of: #""cores":10"#, with: #""cores":10,"swap":1"#))

        #expect(stats.cpu?.cores == 10)
    }

    @Test func derivesUsedFractions() throws {
        let stats = try Self.decode(Self.full)

        #expect(stats.cpu?.fraction == 0.375)
        #expect(stats.memory?.fraction == 0.5)
        #expect(stats.disk?.fraction == 0.25)
    }

    @Test func zeroTotalHasNoFraction() {
        #expect(LeoMachineStats.Memory(usedBytes: 5, totalBytes: 0).fraction == nil)
        #expect(LeoMachineStats.Disk(path: "/", usedBytes: 5, totalBytes: 0).fraction == nil)
    }

    @Test func fractionIsClampedToTheMeter() {
        #expect(LeoMachineStats.Memory(usedBytes: 20, totalBytes: 10).fraction == 1)
        #expect(LeoMachineStats.CPU(percent: 130, cores: 1).fraction == 1)
    }
}
