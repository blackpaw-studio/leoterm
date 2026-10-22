import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A machine section's header: meter text and levels, tooltips, and what the
/// connection state allows.
@MainActor struct LeoMachineHeaderPresentationTests {
    private static let gb: Int64 = 1_073_741_824
    private let now = Date(timeIntervalSince1970: 1_000)

    // MARK: Meters

    @Test func aSampleGivesCpuMemoryAndDiskMetersWithTheirText() throws {
        let header = presentation(stats: stats(cpu: 23, memory: (Int64(3.1 * Double(Self.gb)), 16 * Self.gb)))

        let meters = try values(header)
        #expect(meters.map(\.metric) == [.cpu, .memory, .disk])
        #expect(meters[0].valueText == "23%")
        #expect(meters[1].valueText == "3.1/16 GB")
        #expect(meters[2].valueText == "412/994 GB")
        #expect(meters.allSatisfy { $0.level == .normal })
    }

    @Test func metersTurnAmberAtEightyPercentAndRedAtNinety() throws {
        let header = presentation(stats: stats(cpu: 90, memory: (27 * Self.gb, 32 * Self.gb), disk: (79, 100)))

        let meters = try values(header)
        #expect(meters.map(\.level) == [.critical, .warning, .normal])
    }

    @Test func aTerabyteVolumeReadsInTerabytes() throws {
        let tb = Self.gb * 1024
        let header = presentation(stats: stats(cpu: 1, disk: (tb / 2, 2 * tb)))

        #expect(try values(header)[2].valueText == "0.5/2 TB")
    }

    @Test func aNullCpuPercentShowsADashWithAnEmptyMeter() throws {
        let header = presentation(stats: stats(cpu: nil))

        let cpu = try values(header)[0]
        #expect(cpu.valueText == "—")
        #expect(cpu.fraction == nil)
        #expect(cpu.tooltip == "CPU 8 cores · measuring")
    }

    @Test func aNullSectionBlanksOnlyItsOwnMeter() throws {
        let sample = LeoMachineStats(
            sampledAt: now, cpu: .init(percent: 10, cores: 4), memory: nil,
            disk: .init(path: "/state", usedBytes: Self.gb, totalBytes: 10 * Self.gb)
        )

        let meters = try values(presentation(stats: sample))

        #expect(meters.map(\.valueText) == ["10%", "—", "1/10 GB"])
        #expect(meters[1].tooltip == "Memory unavailable")
    }

    // MARK: Tooltips

    @Test func tooltipsCarryTheExactFiguresAndTheSampleAge() throws {
        let sample = LeoMachineStats(
            sampledAt: now.addingTimeInterval(-3), cpu: .init(percent: 23.4, cores: 8),
            memory: .init(usedBytes: Int64(27.2 * Double(Self.gb)), totalBytes: 32 * Self.gb),
            disk: .init(path: "/Users/evan/.leo", usedBytes: 412 * Self.gb, totalBytes: 994 * Self.gb)
        )

        let meters = try values(presentation(stats: sample))

        #expect(meters[0].tooltip == "CPU 23% · 8 cores · Sampled 3 s ago")
        #expect(meters[1].tooltip == "27.2 GB of 32 GB used (85%) · Sampled 3 s ago")
        #expect(meters[2].tooltip == "412 GB of 994 GB used (41%) · /Users/evan/.leo · Sampled 3 s ago")
    }

    @Test func sampleAgeReadsInMinutesOnceStale() {
        #expect(LeoMachineHeaderPresentation.sampledText(now, now: now) == "Sampled just now")
        #expect(LeoMachineHeaderPresentation.sampledText(now.addingTimeInterval(-125), now: now) == "Sampled 2 min ago")
    }

    // MARK: No stats

    @Test func aDaemonWithoutTheStatsFeatureShowsDimmedEmptyMeters() {
        let header = presentation(stats: nil, features: .none)

        #expect(header.meters == .unavailable(tooltip: "Stats unavailable: this machine's daemon doesn't report them"))
    }

    @Test func aStatsDaemonBeforeItsFirstSampleSaysItIsWaiting() {
        let header = presentation(stats: nil, features: Self.statsFeatures)

        #expect(header.meters == .unavailable(tooltip: "Waiting for the first stats sample"))
    }

    @Test func styleOffHidesEveryMeter() {
        #expect(presentation(stats: stats(cpu: 5), style: .off).meters == .hidden)
    }

    // MARK: Connection

    @Test func aFailedMachineIsOfflineDimmedFoldedAndHasNoMeters() {
        let header = presentation(connectivity: .failed(message: "ssh: connect to host hestia port 22: Operation timed out"), stats: stats(cpu: 5))

        #expect(header.isOffline)
        #expect(header.isDimmed)
        #expect(header.dot == .offline)
        #expect(header.isCollapsed)
        #expect(!header.canToggleCollapse)
        #expect(header.reason == "ssh: connect to host hestia port 22: Operation timed out")
        #expect(header.meters == .hidden)
        #expect(header.showsReconnectButton)
        #expect(!header.canNewAgentHere)
    }

    @Test func aDroppedMachineIsOfflineButOneRetryingShowsNoReconnectButton() {
        let dropped = presentation(connectivity: .disconnected(reason: "tunnel exited", isRetrying: false))
        let retrying = presentation(connectivity: .disconnected(reason: "tunnel exited", isRetrying: true))

        #expect(dropped.isOffline && dropped.showsReconnectButton)
        #expect(retrying.isOffline && !retrying.showsReconnectButton)
        #expect(retrying.dot == .connecting)
        #expect(!retrying.canReconnect)
    }

    @Test func aMachineStillConnectingIsNeitherOfflineNorOpenToNewAgents() {
        let header = presentation(connectivity: .loading)

        #expect(header.dot == .connecting)
        #expect(!header.isOffline)
        #expect(!header.canNewAgentHere)
        #expect(header.canReconnect)
        #expect(header.meters == .hidden)
    }

    @Test func newAgentHereIsEnabledOnlyWhenConnected() {
        #expect(presentation().canNewAgentHere)
        #expect(!presentation(connectivity: .failed(message: "x")).canNewAgentHere)
    }

    // MARK: Names and counts

    @Test func thisMacCarriesItsHostnameInTheTooltip() {
        let local = presentation(host: .local)
        let remote = presentation(host: .remote("dionysus"))

        #expect(local.name == "This Mac")
        #expect(local.nameTooltip == "evans-mbp.local")
        #expect(remote.name == "dionysus")
        #expect(remote.nameTooltip == nil)
    }

    @Test func aFoldedMachineWithAgentsNeedingYouShowsThatCountInOrange() {
        let open = presentation(attention: 2, agents: 5, isCollapsed: false)
        let folded = presentation(attention: 2, agents: 5, isCollapsed: true)

        #expect(open.count == 5 && !open.isAlertCount)
        #expect(folded.count == 2 && folded.isAlertCount)
    }

    // MARK: Helpers

    static let statsFeatures = LeoDaemonFeatures(["machine_stats"])

    private func values(_ header: LeoMachineHeaderPresentation) throws -> [LeoMachineHeaderPresentation.Meter] {
        guard case .values(let meters) = header.meters else {
            Issue.record("expected meter values, got \(header.meters)")
            throw CancellationError()
        }
        return meters
    }

    private func presentation(
        host: LeoHostID = .local, connectivity: LeoConnectivity = .connected, stats: LeoMachineStats? = nil,
        features: LeoDaemonFeatures = LeoMachineHeaderPresentationTests.statsFeatures, style: LeoStatsStyle = .capsules,
        attention: Int = 0, agents: Int = 0, isCollapsed: Bool = false
    ) -> LeoMachineHeaderPresentation {
        let rows = (0..<agents).map { index in
            LeoAgentRow(
                host: host, name: "a\(index)", template: nil, status: .running, activity: .idle, actionDetail: nil,
                attention: nil, startedAt: "s"
            )
        }
        let section = LeoMachineSection(
            host: host, connectivity: connectivity,
            sections: rows.isEmpty ? [] : [LeoSidebarSection(id: "running", title: "Running", rows: rows)],
            isCollapsed: isCollapsed, attentionCount: attention, features: features, stats: stats
        )
        return LeoMachineHeaderPresentation(section: section, style: style, hostName: "evans-mbp.local", now: now)
    }

    private func stats(
        cpu: Double?, memory: (Int64, Int64) = (8 * 1_073_741_824, 16 * 1_073_741_824), disk: (Int64, Int64) = (412 * 1_073_741_824, 994 * 1_073_741_824)
    ) -> LeoMachineStats {
        LeoMachineStats(
            sampledAt: now, cpu: .init(percent: cpu, cores: 8),
            memory: .init(usedBytes: memory.0, totalBytes: memory.1),
            disk: .init(path: "/state", usedBytes: disk.0, totalBytes: disk.1)
        )
    }
}
