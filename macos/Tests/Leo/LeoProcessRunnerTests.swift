import Foundation
import Testing

@testable import Ghostty

struct LeoProcessRunnerTests {
    @Test func fastProcessesAlwaysCaptureOutput() async throws {
        let runner = LeoProcessRunner()
        for _ in 0..<50 {
            let start = ContinuousClock.now
            let result = try await runner.run(executable: "/bin/echo", arguments: ["hi"], timeout: 1)
            #expect(start.duration(to: .now) < .seconds(1))
            #expect(result.stdout == Data("hi\n".utf8))
        }
    }

    @Test func capturesLargeOutputWithoutDeadlocking() async throws {
        let result = try await LeoProcessRunner().run(
            executable: "/bin/sh",
            arguments: ["-c", "yes | head -c 200000"],
            timeout: 1
        )
        #expect(result.stdout.count == 200_000)
    }

    @Test func timeoutTerminatesProcess() async {
        let start = ContinuousClock.now
        do {
            _ = try await LeoProcessRunner().run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.2)
            Issue.record("Expected process to time out")
        } catch let error as LeoDaemonError {
            #expect(error == .timeout)
            #expect(start.duration(to: .now) < .seconds(1))
        } catch {
            Issue.record("Expected timeout, got \(error)")
        }
    }

    /// A process that ignores SIGTERM must still complete via the SIGKILL
    /// escalation 1s after the original deadline. The escalation is stepped
    /// by hand, so this checks what happens at each deadline, not how long
    /// the machine takes to get there.
    @Test func timeoutEscalatesToSIGKILLWhenTheProcessIgnoresSIGTERM() async throws {
        let scheduler = ManualScheduler()
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("leo-sigkill-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        // `exec` keeps the ignored SIGTERM and makes `sleep` the one process
        // holding the pipes, so it dies to SIGKILL alone. It outlives the
        // hang guard (so a missing SIGKILL fails rather than ending
        // naturally) but is self-limiting, so no failure leaves it for long.
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; exec sleep \(Int(Self.hangGuard * 2))"
        let outcome = Outcome()
        let run = Task {
            do {
                let result = try await LeoProcessRunner(scheduler: scheduler.scheduler)
                    .run(executable: "/bin/sh", arguments: ["-c", script], timeout: 0.2)
                await outcome.set(.success(result))
            } catch {
                await outcome.set(.failure(error))
            }
        }

        do {
            try await stepEscalation(scheduler: scheduler, pidFile: pidFile, outcome: outcome)
        } catch {
            await endChild(scheduler: scheduler, pidFile: pidFile, outcome: outcome)
            throw error
        }
        await run.value

        let result = await outcome.value
        #expect(throws: LeoDaemonError.timeout) { try result?.get() }
        // It ended because the process died, not because the drain timer
        // (still pending) gave up on it; firing that now changes nothing.
        #expect(scheduler.delays == [1])
        scheduler.fireNext()
    }

    private func stepEscalation(scheduler: ManualScheduler, pidFile: URL, outcome: Outcome) async throws {
        await awaitCondition(timeout: Self.hangGuard, message: "Process never started") { Self.pid(in: pidFile) != nil }
        let child = try #require(Self.pid(in: pidFile))
        #expect(scheduler.delays == [0.2])

        scheduler.fireNext() // the deadline: SIGTERM, ignored
        #expect(kill(child, 0) == 0, "The process should have ignored SIGTERM")
        #expect(scheduler.delays == [1])

        scheduler.fireNext() // the grace period: SIGKILL
        await awaitCondition(timeout: Self.hangGuard, message: "SIGKILL never ended the run") { await outcome.value != nil }
        if await outcome.value == nil { throw CancellationError() }
    }

    /// After a failed step: let the runner escalate on its own, wait
    /// (bounded) for the run to end, and only if it still hasn't -- so the
    /// child is unreaped and its pid still ours -- kill it directly.
    private func endChild(scheduler: ManualScheduler, pidFile: URL, outcome: Outcome) async {
        scheduler.fireAll()
        await awaitCondition(timeout: Self.hangGuard, message: "The run never ended") { await outcome.value != nil }
        if await outcome.value == nil, let pid = Self.pid(in: pidFile), Self.isOurChild(pid) { kill(pid, SIGKILL) }
    }

    /// The pid still names a child of this process -- not one reused by a
    /// stranger after the child exited.
    private static func isOurChild(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_ppid == UInt32(getpid())
    }

    private static func pid(in file: URL) -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The app's scheduler really runs what the escalation schedules: blocks
    /// fire, never before their delay, and a long delay isn't cut short by
    /// shorter ones firing. The due blocks run on a concurrent queue, so
    /// their relative order isn't asserted. No upper bound on when: only
    /// `hangGuard` turns a hang into a failure.
    @Test func dispatchSchedulerRunsBlocksNoSoonerThanTheirDelay() async {
        let fired = FiredLog()
        let start = ContinuousClock.now
        LeoProcessScheduler.dispatch.after(3600) { fired.append("long") }
        LeoProcessScheduler.dispatch.after(0.2) { fired.append("short:\(start.duration(to: .now) >= .milliseconds(200))") }
        LeoProcessScheduler.dispatch.after(0) { fired.append("sentinel") }

        await awaitCondition(timeout: Self.hangGuard, message: "The scheduled blocks never fired") { fired.entries.count >= 2 }

        #expect(fired.entries.sorted() == ["sentinel", "short:true"])
    }

    /// Only turns a hang into a failure: nothing here is timed against it.
    static let hangGuard: TimeInterval = 60
}

private final class FiredLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var entries: [String] { lock.withLock { log } }
    func append(_ entry: String) { lock.withLock { log.append(entry) } }
}

/// Holds scheduled actions until the test fires them, in order.
private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(delay: TimeInterval, action: @Sendable () -> Void)] = []

    var scheduler: LeoProcessScheduler {
        LeoProcessScheduler { [self] delay, action in lock.withLock { pending.append((delay, action)) } }
    }

    var delays: [TimeInterval] { lock.withLock { pending.map(\.delay) } }

    /// Fires everything, including what firing schedules.
    func fireAll() {
        while !delays.isEmpty { fireNext() }
    }

    func fireNext() {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.action()
    }
}

private actor Outcome {
    private(set) var value: Result<LeoProcessResult, Error>?
    func set(_ result: Result<LeoProcessResult, Error>) { value = result }
}
