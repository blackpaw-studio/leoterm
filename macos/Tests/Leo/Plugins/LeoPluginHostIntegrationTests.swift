import Darwin
import Foundation
import Testing

import LeoKit
@testable import Ghostty

/// Collects what a connection reports and lets a test wait for it. Waiting
/// blocks a pool thread, not the cooperative one, so the callbacks (which run
/// on their own queue) are never starved.
private final class HostProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var requests: [LeoPluginHostRequest] = []
    private var termination: LeoPluginHostTermination?
    let queue = DispatchQueue(label: "leo.plugin.test.callbacks")

    func attach(to connection: LeoPluginHostConnection) {
        connection.onRequest = { [self] request in
            condition.lock()
            requests.append(request)
            condition.broadcast()
            condition.unlock()
        }
        connection.onTermination = { [self] ended in
            condition.lock()
            termination = ended
            condition.broadcast()
            condition.unlock()
        }
    }

    /// The first `count` requests, or fewer if the wait times out.
    func requests(count: Int, timeout: TimeInterval = 30) async -> [LeoPluginHostRequest] {
        await blocking { [self] in
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date(timeIntervalSinceNow: timeout)
            while requests.count < count, condition.wait(until: deadline) {}
            return Array(requests.prefix(count))
        }
    }

    func terminated(timeout: TimeInterval = 30) async -> LeoPluginHostTermination? {
        await blocking { [self] in
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date(timeIntervalSinceNow: timeout)
            while termination == nil, condition.wait(until: deadline) {}
            return termination
        }
    }

    private func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }
}

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Plugins
        .deletingLastPathComponent()  // Leo
        .deletingLastPathComponent()  // Tests
        .appendingPathComponent("Fixtures/Plugins/\(name)/\(name).js")
    return try String(contentsOf: url, encoding: .utf8)
}

private func logs(_ requests: [LeoPluginHostRequest]) -> [String] {
    requests.compactMap { if case .log(_, let message) = $0 { message } else { nil } }
}

/// Real helper process, real socketpair. `CODE_SIGNING_ALLOWED=NO` builds don't
/// enforce the sandbox; the signed-build check covers that.
struct LeoPluginHostIntegrationTests {
    private let agent = LeoPluginAgentRef(machine: "local", name: "alfred")

    /// Tight limits so a runaway is caught in tens of milliseconds, not seconds.
    private let fast = LeoPluginHostConnection.Configuration(
        pollInterval: 0.02, cpuBudgetSeconds: 0.25, memoryLimitBytes: 96 * 1_048_576, memoryCheckInterval: 0.02)

    private func makeConnection(
        _ configuration: LeoPluginHostConnection.Configuration = LeoPluginHostConnection.Configuration()
    ) -> (LeoPluginHostConnection, HostProbe) {
        let probe = HostProbe()
        let connection = LeoPluginHostConnection(
            launcher: LeoPluginPosixLauncher.embedded(), configuration: configuration, callbackQueue: probe.queue)
        probe.attach(to: connection)
        return (connection, probe)
    }

    @Test func bridgeRoundTripsEventsAndRepliesBothWays() async throws {
        let (connection, probe) = makeConnection()
        defer { connection.stop() }
        try connection.start(source: try fixture("echo"))
        try connection.deliver(.activate(slot: nil))

        let first = await probe.requests(count: 3)
        #expect(logs(first) == ["echo:loaded", "echo:activate"])
        guard case .fetch(let id, let url, _)? = first.last else {
            Issue.record("expected the fetch request, got \(first)")
            return
        }
        #expect(url == "https://example.test/echo")

        try connection.deliver(.reply(id: id, outcome: .value(.object(["status": .int(200)]))))
        let all = await probe.requests(count: 4)
        #expect(logs(all) == ["echo:loaded", "echo:activate", "echo:fetched 200"])
    }

    @Test func aPanePluginRendersItsSlotsAndFollowsUsageChangedThroughTheRealHost() async throws {
        let (connection, probe) = makeConnection()
        defer { connection.stop() }
        try connection.start(source: try fixture("pane-demo"))
        let summary = LeoPluginSlotID.pane(id: "demo", part: .summary, agent: agent)
        let body = LeoPluginSlotID.pane(id: "demo", part: .body, agent: agent)
        try connection.deliver(.viewOpened(agent: agent, slot: summary))
        try connection.deliver(.viewOpened(agent: agent, slot: body))

        // loaded, summary (first open), summary again and body (second open).
        let opened = await probe.requests(count: 4)
        let renders: [(LeoPluginSlotID, LeoPluginSlotRoot)] = opened.compactMap {
            if case .render(let slot, let node) = $0 { (slot, node) } else { nil }
        }
        #expect(renders.map(\.0) == [summary, summary, body])
        let summaryRoot = try #require(renders.first?.1)
        #expect(LeoPluginPaneSummaryRules.violation(in: summaryRoot) == nil)
        #expect(summaryRoot.nodes.count == 3)
        guard case .text(let bodyText)? = renders.last?.1.nodes.first else {
            Issue.record("expected the body to open with a Text of every tone")
            return
        }
        #expect(Set(bodyText.runs.compactMap(\.tone)) == Set(LeoPluginTone.allCases))

        try connection.deliver(.usageChanged(agent: agent))
        let asked = await probe.requests(count: 5)
        guard case .agentsUsage(let id, let askedAbout)? = asked.last else {
            Issue.record("expected the plugin to read agents.usage, got \(asked.last as Any)")
            return
        }
        #expect(askedAbout == agent)
        try connection.deliver(.reply(id: id, outcome: .value(.object(["session": .object(["tokens": .int(4_242)])]))))

        // The usage log, then both slots re-rendered with the new tokens.
        let after = await probe.requests(count: 8)
        guard case .render(_, let updated)? = after[6..<8].first, case .text(let line)? = updated.nodes.first else {
            Issue.record("expected the summary to re-render, got \(after.suffix(3))")
            return
        }
        #expect(line.plainText.contains("4242 tok"))
    }

    @Test func aHandlerThatNeverReturnsIsKilledAsACPUCrash() async throws {
        let (connection, probe) = makeConnection(fast)
        try connection.start(source: try fixture("spin"))
        try connection.deliver(.agentsChanged)
        guard case .crashed(let reason)? = await probe.terminated() else {
            Issue.record("expected a crash")
            return
        }
        #expect(reason.contains("CPU"))
    }

    @Test func aHostThatHoardsMemoryIsKilledAsAMemoryCrash() async throws {
        // A generous CPU budget so the memory cap is what trips.
        var config = fast
        config.cpuBudgetSeconds = 60
        let (connection, probe) = makeConnection(config)
        try connection.start(source: try fixture("leak"))
        try connection.deliver(.agentsChanged)
        guard case .crashed(let reason)? = await probe.terminated() else {
            Issue.record("expected a crash")
            return
        }
        #expect(reason.contains("memory"))
    }

    @Test func aHandlerThatAllocatesAndReturnsIsStillKilledForMemory() async throws {
        // Production limits: the 256 MB cap, polled at 1 s, plus the check on `done`.
        let (connection, probe) = makeConnection()
        try connection.start(source: try fixture("hog"))
        try connection.deliver(.agentsChanged)
        let started = Date()
        guard case .crashed(let reason)? = await probe.terminated(timeout: 10) else {
            Issue.record("expected a crash")
            return
        }
        #expect(reason.contains("memory"))
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func aRequestFloodIsKilledByTheQuotaAndStopsDeliveringAfterwards() async throws {
        let (connection, probe) = makeConnection()
        try connection.start(source: try fixture("flood"))
        try connection.deliver(.agentsChanged)
        guard case .crashed(let reason)? = await probe.terminated(timeout: 20) else {
            Issue.record("expected a crash")
            return
        }
        #expect(reason.contains("requests") || reason.contains("MB"))
        let delivered = await probe.requests(count: 10_000, timeout: 0.5).count
        #expect(delivered <= LeoPluginRequestQuota.defaultMaxRequests + 2)
    }

    @Test func aSlowMainQueueMakesTheReaderPauseSoDeliveriesStayBounded() async throws {
        let (connection, probe) = makeConnection()
        let gate = DispatchSemaphore(value: 0)
        probe.queue.async { gate.wait() }  // the app's main queue is stuck
        try connection.start(source: try fixture("flood"))
        try connection.deliver(.agentsChanged)

        // Let the helper flood until the reader pauses and the helper blocks.
        try await Task.sleep(for: .seconds(1))
        let peak = connection.outstandingRequests
        try await Task.sleep(for: .milliseconds(500))
        #expect(connection.outstandingRequests == peak, "reading should have stopped")
        #expect(peak <= LeoPluginBackpressure.defaultHighWater + 1)

        gate.signal()  // main drains; the helper resumes and then hits the quota
        guard case .crashed? = await probe.terminated(timeout: 20) else {
            Issue.record("expected the quota to kill the helper once the queue drained")
            return
        }
    }

    @Test func anExternalSIGKILLIsACrashAndTheSupervisorSaysRestartAfterOneSecond() async throws {
        let (connection, probe) = makeConnection()
        try connection.start(source: try fixture("echo"))
        _ = await probe.requests(count: 1)
        let pid = try #require(connection.pid)
        kill(pid, SIGKILL)

        guard case .crashed(let reason)? = await probe.terminated() else {
            Issue.record("expected a crash")
            return
        }
        #expect(reason.contains("signal 9"))
        var supervisor = LeoPluginSupervisor()
        #expect(supervisor.recordCrash(reason: reason, at: 0) == .restart(after: 1))

        // The "restart": a fresh connection comes up and works.
        let (restarted, restartedProbe) = makeConnection()
        defer { restarted.stop() }
        try restarted.start(source: try fixture("echo"))
        #expect(logs(await restartedProbe.requests(count: 1)) == ["echo:loaded"])
        #expect(restarted.pid != pid)
    }

    @Test func threeCrashesWithinTheWindowDisableThePlugin() async throws {
        var supervisor = LeoPluginSupervisor()
        var decisions: [LeoPluginSupervisor.Decision] = []
        for attempt in 0..<3 {
            let (connection, probe) = makeConnection(fast)
            try connection.start(source: try fixture("spin"))
            try connection.deliver(.agentsChanged)
            guard case .crashed(let reason)? = await probe.terminated() else {
                Issue.record("attempt \(attempt) did not crash")
                return
            }
            // Scaled clock: the real backoff delays are never waited out.
            decisions.append(supervisor.recordCrash(reason: reason, at: Double(attempt) * 10))
        }
        guard case .disable(let reason) = decisions.last else {
            Issue.record("expected disable, got \(decisions)")
            return
        }
        #expect(decisions.dropLast() == [.restart(after: 1), .restart(after: 5)])
        #expect(reason.contains("CPU"))
    }

    @Test func stopEndsTheHostWithoutCountingACrash() async throws {
        let (connection, probe) = makeConnection()
        try connection.start(source: try fixture("echo"))
        _ = await probe.requests(count: 1)
        connection.stop()
        #expect(await probe.terminated() == .stopped)
        #expect(throws: LeoPluginHostConnection.ConnectionError.notRunning) { try connection.deliver(.agentsChanged) }
    }

    @Test func aBundleThatThrowsOnLoadIsReportedNotCrashed() async throws {
        let (connection, probe) = makeConnection()
        defer { connection.stop() }
        try connection.start(source: "throw new Error('bad bundle')")
        let requests = await probe.requests(count: 1)
        guard case .handlerError(let source, let message)? = requests.first else {
            Issue.record("expected handlerError, got \(requests)")
            return
        }
        #expect(source == "load")
        #expect(message.contains("bad bundle"))
    }

    @Test func aMissingHelperFailsToStart() {
        let probe = HostProbe()
        let connection = LeoPluginHostConnection(
            launcher: LeoPluginPosixLauncher(helperURL: URL(fileURLWithPath: "/nonexistent/LeoPluginHost")),
            callbackQueue: probe.queue)
        #expect(throws: LeoPluginHostLaunchError.helperMissing("/nonexistent/LeoPluginHost")) {
            try connection.start(source: "")
        }
    }

    @Test func theHelperStartsWithAnEmptyEnvironmentAndNoStrayDescriptors() async throws {
        // The fixture can't read env/fds, so check from the outside: the helper's
        // only open descriptors are 0-2 and the socket on 3.
        let (connection, probe) = makeConnection()
        defer { connection.stop() }
        try connection.start(source: try fixture("echo"))
        _ = await probe.requests(count: 1)
        let pid = try #require(connection.pid)
        let output = try runTool("/usr/sbin/lsof", ["-nP", "-p", "\(pid)", "-a", "-d", "0-99"])
        let descriptors = output.split(separator: "\n").dropFirst()
            .compactMap { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first }
            .map { String($0).filter(\.isNumber) }
            .compactMap(Int.init)
        #expect(descriptors.allSatisfy { $0 <= 3 }, "unexpected descriptors: \(descriptors)")
    }

    @Test func theHelperStdinAndStdoutAreDevNull() async throws {
        let (connection, probe) = makeConnection()
        defer { connection.stop() }
        try connection.start(source: try fixture("echo"))
        _ = await probe.requests(count: 1)
        let pid = try #require(connection.pid)
        // `lsof -F fn`: an "f<fd>" line, then that descriptor's "n<name>" line.
        let output = try runTool("/usr/sbin/lsof", ["-nP", "-p", "\(pid)", "-a", "-d", "0,1", "-F", "fn"])
        var names: [String: String] = [:]
        var current: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("f") { current = String(line.dropFirst()) }
            if line.hasPrefix("n"), let fd = current { names[fd] = String(line.dropFirst()) }
        }
        #expect(names["0"] == "/dev/null")
        #expect(names["1"] == "/dev/null")
    }

    @Test func repeatedStartAndStopCyclesAllEndCleanly() async throws {
        for _ in 0..<10 {
            let (connection, probe) = makeConnection()
            try connection.start(source: try fixture("echo"))
            _ = await probe.requests(count: 1)
            connection.stop()
            #expect(await probe.terminated() == .stopped)
        }
    }

    private func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}

struct LeoPluginProcessUsageTests {
    @Test func readsCPUAndFootprintForTheCurrentProcess() throws {
        let usage = try #require(LeoPluginProcessUsage.read(pid: getpid()))
        #expect(usage.cpuSeconds > 0)
        #expect(usage.footprintBytes > 1_000_000)
    }

    @Test func aMissingProcessReadsAsNil() {
        #expect(LeoPluginProcessUsage.read(pid: 2_000_000) == nil)
    }
}

struct LeoPluginHostOrphanReaperTests {
    private let helper = "/Applications/Leo.app/Contents/Helpers/LeoPluginHost"

    @Test func onlyHelpersAdoptedByLaunchdAreOrphans() {
        let processes: [LeoPluginHostOrphanReaper.Candidate] = [
            .init(pid: 10, parentPID: 1, path: helper),  // orphaned helper
            .init(pid: 11, parentPID: 500, path: helper),  // live helper of a running Leo
            .init(pid: 12, parentPID: 1, path: "/usr/bin/other"),  // unrelated daemon
            .init(pid: 13, parentPID: 1, path: helper + "-debug"),  // other path
        ]
        #expect(LeoPluginHostOrphanReaper.orphans(in: processes, helperPath: helper) == [10])
    }
}
