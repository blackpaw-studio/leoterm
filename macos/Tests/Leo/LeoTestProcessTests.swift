import Darwin
import Foundation
import Testing

@testable import Ghostty

/// B-121: `LeoTestProcess.gone()` hands out a reaped pid, and a reaped pid
/// can be reused by a live process before the test uses it. The pid is
/// checked gone (`ESRCH`) at hand-out, and a reused one is never handed out.
struct LeoTestProcessTests {
    /// Stands in for the kernel: the pids it's asked about, and which of
    /// them a live process has taken over.
    private final class Probe {
        private(set) var asked: [pid_t] = []
        private let reused: (Int) -> Bool

        /// `reused(n)` answers the `n`th question (0-based).
        init(reused: @escaping (Int) -> Bool) { self.reused = reused }

        func isGone(_ pid: pid_t) -> Bool {
            defer { asked.append(pid) }
            return !reused(asked.count)
        }
    }

    @Test func goneHandsOutAPidNothingIsRunningAs() throws {
        let pid = try LeoTestProcess.gone()

        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func goneNeverHandsOutAPidALiveProcessHasTakenOver() throws {
        let probe = Probe(reused: { $0 == 0 })

        let pid = try LeoTestProcess.gone(isGone: probe.isGone)

        #expect(probe.asked.count == 2, "a reused pid is replaced by a fresh one")
        #expect(probe.asked.last == pid, "the pid handed out is the one checked gone")
        #expect(probe.asked.first != pid)
    }

    @Test func goneGivesUpWhenEveryPidIsTakenOver() {
        let probe = Probe(reused: { _ in true })

        #expect(throws: LeoTestProcess.GoneError.self) { try LeoTestProcess.gone(isGone: probe.isGone) }
        #expect(probe.asked.count == LeoTestProcess.maxGoneAttempts)
    }

    @Test func isGoneIsTrueOnlyForAPidNothingIsRunningAs() throws {
        let child = try LeoTestChild("/bin/sleep", ["60"])
        defer { child.stop() }
        let pid = child.pid

        #expect(!LeoTestProcess.isGone(getpid()))
        #expect(!LeoTestProcess.isGone(pid), "running")
        child.stop()
        #expect(LeoTestProcess.isGone(pid), "reaped")
    }
}
