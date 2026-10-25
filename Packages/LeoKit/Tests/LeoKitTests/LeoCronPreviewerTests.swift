import Foundation
import Testing

@testable import LeoKit

/// A sleeper the test advances by hand: no real waiting. Every `sleep` parks
/// until `advance` passes its deadline, or throws if its task is cancelled.
actor ManualSleeper {
    private struct Waiter {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var now = Duration.zero
    private var waiters: [Int: Waiter] = [:]
    private var next = 0
    private var cancelled: Set<Int> = []

    var pending: Int { waiters.count }

    func sleep(for duration: Duration) async throws {
        let id = next
        next += 1
        let deadline = now + duration
        try await withTaskCancellationHandler(
            operation: { () async throws in try await self.park(id, until: deadline) },
            onCancel: { Task { await self.cancel(id) } }
        )
    }

    private func park(_ id: Int, until deadline: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if cancelled.remove(id) != nil {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters[id] = Waiter(deadline: deadline, continuation: continuation)
            }
        }
    }

    func advance(by duration: Duration) {
        now += duration
        for (id, waiter) in waiters where waiter.deadline <= now {
            waiters[id] = nil
            waiter.continuation.resume()
        }
    }

    /// A cancel that beats the sleep to its parking spot is remembered.
    private func cancel(_ id: Int) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }
}

/// Records what the previewer asked the daemon, and answers by expression.
actor CronFetches {
    private(set) var expressions: [String] = []
    var failing: Set<String> = []
    private var held: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]

    func fail(_ expression: String) { failing.insert(expression) }

    /// The next answer to `expression` waits for `release`.
    func hold(_ expression: String) { held.insert(expression) }

    func release(_ expression: String) {
        held.remove(expression)
        gates.removeValue(forKey: expression)?.resume()
    }

    func answer(_ expression: String) async throws -> LeoCronPreview {
        expressions.append(expression)
        if held.contains(expression) { await withCheckedContinuation { gates[expression] = $0 } }
        if failing.contains(expression) { throw LeoDaemonError.daemon(code: "unavailable", message: "down", matches: []) }
        let fields = expression.split(separator: " ").count
        return fields == 5
            ? LeoCronPreview(valid: true, description: "ok: \(expression)", error: nil)
            : LeoCronPreview(valid: false, description: "", error: "expected 5 fields, got \(fields)")
    }
}

struct LeoCronPreviewerTests {
    private struct Rig {
        let sleeper = ManualSleeper()
        let fetches = CronFetches()
        let previewer: LeoCronPreviewer

        init() {
            let sleeper = sleeper
            let fetches = fetches
            previewer = LeoCronPreviewer(debounce: .milliseconds(400), sleep: { try await sleeper.sleep(for: $0) }, fetch: { try await fetches.answer($0) })
        }

        /// Starts a preview and waits until it is parked on the debounce.
        func start(_ expression: String) async -> Task<LeoCronPreviewResult?, Never> {
            let before = await sleeper.pending
            let task = Task { await previewer.preview(expression) }
            while await sleeper.pending == before { await Task.yield() }
            return task
        }
    }

    @Test func aPreviewWaitsOutTheDebounceThenAsksOnce() async throws {
        let rig = Rig()
        let task = await rig.start("0 3 * * *")

        await rig.sleeper.advance(by: .milliseconds(399))
        #expect(await rig.fetches.expressions.isEmpty)

        await rig.sleeper.advance(by: .milliseconds(1))
        #expect(await task.value == .valid("ok: 0 3 * * *"))
        #expect(await rig.fetches.expressions == ["0 3 * * *"])
    }

    @Test func typingOnAsksOnlyTheLatestExpression() async throws {
        let rig = Rig()
        let first = await rig.start("0 3 * *")
        let second = await rig.start("0 3 * * *")

        await rig.sleeper.advance(by: .milliseconds(400))

        #expect(await first.value == nil)
        #expect(await second.value == .valid("ok: 0 3 * * *"))
        #expect(await rig.fetches.expressions == ["0 3 * * *"])
    }

    @Test func anInvalidExpressionCarriesTheDaemonsReason() async throws {
        let rig = Rig()
        let task = await rig.start("0 3 *")
        await rig.sleeper.advance(by: .milliseconds(400))

        #expect(await task.value == .invalid("expected 5 fields, got 3"))
    }

    @Test func aCancelledPreviewNeverAsks() async throws {
        let rig = Rig()
        let task = await rig.start("0 3 * * *")
        task.cancel()

        #expect(await task.value == nil)
        await rig.sleeper.advance(by: .seconds(5))
        #expect(await rig.fetches.expressions.isEmpty)
    }

    @Test func aDaemonThatCannotAnswerShowsNothing() async throws {
        let rig = Rig()
        await rig.fetches.fail("0 3 * * *")
        let task = await rig.start("0 3 * * *")
        await rig.sleeper.advance(by: .milliseconds(400))

        #expect(await task.value == nil)
    }

    @Test func aBlankExpressionIsNeverSent() async throws {
        let rig = Rig()

        #expect(await rig.previewer.preview("   ") == nil)
        #expect(await rig.sleeper.pending == 0)
        #expect(await rig.fetches.expressions.isEmpty)
    }

    @Test func aReplyThatArrivesAfterANewerExpressionIsDropped() async throws {
        let rig = Rig()
        await rig.fetches.hold("0 3 * * *")
        let slow = await rig.start("0 3 * * *")
        await rig.sleeper.advance(by: .milliseconds(400))
        while await rig.fetches.expressions.isEmpty { await Task.yield() }

        let newer = await rig.start("1 3 * * *")
        await rig.fetches.release("0 3 * * *")
        await rig.sleeper.advance(by: .milliseconds(400))

        #expect(await slow.value == nil)
        #expect(await newer.value == .valid("ok: 1 3 * * *"))
    }
}
