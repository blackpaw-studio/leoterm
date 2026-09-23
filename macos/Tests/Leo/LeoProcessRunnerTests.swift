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
        // holding the pipes, so it dies to SIGKILL alone.
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; exec sleep 3600"
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

        await awaitCondition(timeout: Self.hangGuard, message: "Process never started") {
            (try? String(contentsOf: pidFile, encoding: .utf8))?.hasSuffix("\n") == true
        }
        let pid = try #require(pid_t((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(scheduler.delays == [0.2])

        scheduler.fireNext() // the deadline: SIGTERM, ignored
        #expect(kill(pid, 0) == 0, "The process should have ignored SIGTERM")
        #expect(scheduler.delays == [1])

        scheduler.fireNext() // the grace period: SIGKILL
        await awaitCondition(timeout: Self.hangGuard, message: "SIGKILL never ended the run") { await outcome.value != nil }
        if await outcome.value == nil { kill(pid, SIGKILL) }
        await run.value

        let result = await outcome.value
        #expect(throws: LeoDaemonError.timeout) { try result?.get() }
        // It ended because the process died, not because the drain timer
        // (still pending) gave up on it; firing that now changes nothing.
        #expect(scheduler.delays == [1])
        scheduler.fireNext()
    }

    /// Only turns a hang into a failure: nothing here is timed against it.
    static let hangGuard: TimeInterval = 60
}

/// Holds scheduled actions until the test fires them, in order.
private final class ManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(delay: TimeInterval, action: @Sendable () -> Void)] = []

    var scheduler: LeoProcessScheduler {
        LeoProcessScheduler { [self] delay, action in lock.withLock { pending.append((delay, action)) } }
    }

    var delays: [TimeInterval] { lock.withLock { pending.map(\.delay) } }

    func fireNext() {
        let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        next?.action()
    }
}

private actor Outcome {
    private(set) var value: Result<LeoProcessResult, Error>?
    func set(_ result: Result<LeoProcessResult, Error>) { value = result }
}
