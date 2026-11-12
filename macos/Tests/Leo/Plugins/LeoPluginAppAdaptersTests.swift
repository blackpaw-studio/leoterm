import Foundation
import Testing

@testable import LeoKit
@testable import Ghostty

/// The thin app-side adapters under the plugin manager. The logic they feed
/// is tested in LeoKit; these check what only the app can: the real file
/// events, and which row fields reach a plugin.
struct LeoPluginAppAdaptersTests {
    private static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leo-plugin-adapters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test @MainActor func agentCarriesWorkspaceAndModelForTheSnapshotLayerToGate() {
        let row = LeoAgentRow(
            host: .remote("hestia"), name: "fix-login", template: "coder", status: .running, activity: .idle, actionDetail: nil,
            workspace: "/Users/evan/secret/worktree", repo: "blackpaw/leo", branch: "fix/login", model: "claude-opus-5-5")

        let (host, agent) = LeoPluginAppSources.agent(for: row)

        #expect(host == .remote("hestia"))
        #expect(agent.name == "fix-login")
        #expect(agent.repo == "blackpaw/leo")
        #expect(agent.branch == "fix/login")
        // The app hands over everything; `LeoPluginAgentsSnapshot` withholds these without `agents:usage`.
        #expect(agent.workspace == "/Users/evan/secret/worktree")
        #expect(agent.model == "claude-opus-5-5")
    }

    // MARK: Usage

    private static func usage(tokens: Int64 = 100, model: String? = nil) -> LeoAgentUsage {
        LeoAgentUsage(session: LeoUsageTotals(tokens: tokens, costUSD: 0.5), model: model)
    }

    private static func row(
        _ name: String = "alfred", host: LeoHostID = .local, usage: LeoAgentUsage? = nil, harness: String? = "claude",
        model: String? = "claude-sonnet-5-5", movedTo: String? = nil
    ) -> LeoAgentRow {
        LeoAgentRow(
            host: host, name: name, template: nil, status: .running, activity: .idle, actionDetail: nil,
            metadata: usage.map { LeoAgentMetadata(lastActiveAt: nil, isWorking: false, task: nil, usage: $0) },
            movedTo: movedTo, harness: harness, model: model)
    }

    @Test func aReadingCarriesTheConfiguredModelTheUsageAndWhetherTheHarnessReports() {
        let reading = LeoPluginAppSources.usageReading(for: Self.row(usage: Self.usage(), harness: "claude"), daemonReportsUsage: true)

        #expect(reading.configuredModel == "claude-sonnet-5-5")
        #expect(reading.usage == Self.usage())
        #expect(reading.harnessReportsUsage)
    }

    @Test func harnessesThatNeverReportUsageAreMarkedSo() {
        func reports(_ harness: String?, daemon: Bool = true) -> Bool {
            LeoPluginAppSources.usageReading(for: Self.row(harness: harness), daemonReportsUsage: daemon).harnessReportsUsage
        }
        #expect(reports("claude"))
        #expect(reports("codex"))
        #expect(reports(nil), "an agent whose harness isn't known yet may still report")
        #expect(!reports("gemini"))
        #expect(!reports("claude", daemon: false), "a daemon without agent_usage never reports")
    }

    @Test func usageChangesNameAnAgentTheFirstTimeItReportsAndEachTimeItsUsageMoves() {
        var diff = LeoPluginUsageDiff()
        #expect(diff.changes(in: [Self.row("a"), Self.row("b", usage: Self.usage())]) == [.init(machine: "localhost", name: "b")])
        #expect(diff.changes(in: [Self.row("a"), Self.row("b", usage: Self.usage())]).isEmpty)
        #expect(diff.changes(in: [Self.row("a"), Self.row("b", usage: Self.usage(tokens: 200))]) == [.init(machine: "localhost", name: "b")])
    }

    @Test func usageChangesIgnoreAgentsOnOtherMachinesWithTheSameNameButTrackThemSeparately() {
        var diff = LeoPluginUsageDiff()
        let local = Self.row("a", usage: Self.usage())
        let remote = Self.row("a", host: .remote("hestia"), usage: Self.usage())
        #expect(Set(diff.changes(in: [local, remote])).count == 2)
        #expect(diff.changes(in: [local, Self.row("a", host: .remote("hestia"), usage: Self.usage(tokens: 1))]) == [.init(machine: "hestia", name: "a")])
    }

    @Test func usageThatDisappearsIsAChangeAndAMovedRowIsNotTracked() {
        var diff = LeoPluginUsageDiff()
        _ = diff.changes(in: [Self.row("a", usage: Self.usage())])
        #expect(diff.changes(in: [Self.row("a")]) == [.init(machine: "localhost", name: "a")])
        #expect(diff.changes(in: [Self.row("m", usage: Self.usage(), movedTo: "hestia")]).isEmpty)
    }

    @Test func fileEventsReportAWriteToAWatchedFile() async throws {
        let directory = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("main.js")
        try Data("a".utf8).write(to: file)
        let fired = AsyncStream<Void>.makeStream()

        let handle = LeoPluginDispatchFileEvents().watch(file) { fired.continuation.yield() }
        defer { handle?.cancel() }
        try #require(handle != nil)
        let handle2 = try FileHandle(forWritingTo: file)
        try handle2.write(contentsOf: Data("b".utf8))
        try handle2.close()

        var iterator = fired.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func fileEventsRefuseAMissingPath() throws {
        let directory = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let handle = LeoPluginDispatchFileEvents().watch(directory.appendingPathComponent("nope")) {}

        #expect(handle == nil)
    }

    @Test func hostFactoryMakesAFreshConnectionEachTime() {
        let factory = LeoPluginProcessHostFactory(launcher: LeoPluginPosixLauncher(helperURL: URL(fileURLWithPath: "/nonexistent")))

        let first = factory.makeHost()
        let second = factory.makeHost()

        #expect(first as AnyObject !== second as AnyObject)
    }
}
