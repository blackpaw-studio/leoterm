import Foundation
import LeoKit

/// Samples every connected machine's load for the sidebar headers.
///
/// Each machine polls on its own task, so a slow or hung machine never holds
/// up another. A machine polls only while all of these hold: the sidebar is
/// visible and the app is active, the Stats style isn't Off, and the machine
/// is connected and advertises `machine_stats`. `reconcile()` re-evaluates
/// that for every machine and is idempotent, so any input that might have
/// changed (a snapshot, a connection, the style) just calls it.
///
/// Meters clear when a machine can't be shown any (disconnected, no flag,
/// style Off, removed), after `staleAfterMisses` failed polls in a row, and
/// when the daemon refuses: 503 `machine_stats_unavailable`, or 401/403 for a
/// token that can't read it. A refusal stops that machine's polling until its
/// next reconnect. Hiding the sidebar or deactivating the app pauses polling
/// but keeps the last sample, and the next poll starts at once on return.
///
/// Call `stop()` on quit: each poll task holds the poller until it ends.
@MainActor final class LeoMachineStatsPoller {
    static let intervalNanoseconds: UInt64 = 5_000_000_000
    static let requestTimeoutNanoseconds: UInt64 = 3_000_000_000
    /// Consecutive failed polls (15s) after which the last sample is dropped.
    static let staleAfterMisses = 3

    struct Dependencies {
        /// The live client of a connected machine; nil while it has none.
        var daemon: @MainActor (LeoHostID) -> (any LeoDaemonClient)?
        /// The generation of the machine's current connection.
        var generation: @MainActor (LeoHostID) -> Int
        var features: @MainActor (LeoHostID) -> LeoDaemonFeatures
        var style: @MainActor () -> LeoStatsStyle
        /// A machine's new sample; nil clears its meters.
        var deliver: @MainActor (LeoMachineStats?, LeoHostID) -> Void
        var sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    }

    private struct Poll {
        let generation: Int
        let task: Task<Void, Never>
    }

    private let dependencies: Dependencies
    private var machines: [LeoHostID] = []
    private var polls: [LeoHostID: Poll] = [:]
    /// The generation at which a machine refused stats; it polls again once
    /// its connection moves on.
    private var refusals: [LeoHostID: Int] = [:]
    /// Machines whose meters currently show a sample.
    private var sampled: Set<LeoHostID> = []
    private var isSidebarPollable = false
    private var isAppActive = false
    private var isStopped = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// The machines with a running poll.
    var pollingHosts: Set<LeoHostID> { Set(polls.keys) }

    func setMachines(_ hosts: [LeoHostID]) {
        machines = hosts
        let kept = Set(hosts)
        for host in polls.keys where !kept.contains(host) { cancelPoll(host) }
        for host in sampled.subtracting(kept) { clear(host) }
        refusals = refusals.filter { kept.contains($0.key) }
        reconcile()
    }

    /// Whether any window's sidebar is on screen (`hasPollableSidebar`).
    func setSidebarPollable(_ pollable: Bool) {
        isSidebarPollable = pollable
        reconcile()
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        reconcile()
    }

    /// Starts, keeps or stops each machine's poll to match the current inputs.
    func reconcile() {
        guard !isStopped else { return }
        let showsMeters = dependencies.style().showsMeters
        let isLive = isSidebarPollable && isAppActive
        for host in machines {
            let generation = dependencies.generation(host)
            guard showsMeters, refusals[host] != generation,
                  dependencies.features(host).contains(.machineStats),
                  let daemon = dependencies.daemon(host) else {
                cancelPoll(host)
                clear(host)
                continue
            }
            guard isLive else {
                cancelPoll(host)
                continue
            }
            if polls[host]?.generation == generation { continue }
            cancelPoll(host)
            polls[host] = Poll(generation: generation, task: Task { await self.poll(host, daemon: daemon, generation: generation) })
        }
    }

    /// Cancels every poll, and ignores every later input.
    func stop() {
        isStopped = true
        polls.keys.forEach(cancelPoll)
    }

    private func poll(_ host: LeoHostID, daemon: any LeoDaemonClient, generation: Int) async {
        var misses = 0
        while !Task.isCancelled {
            let outcome = await sample(daemon)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .stats(let stats):
                misses = 0
                sampled.insert(host)
                dependencies.deliver(stats, host)
            case .refused:
                refusals[host] = generation
                polls[host] = nil
                clear(host)
                return
            case .miss, .cancelled:
                // `.cancelled` past the guard above is a request that threw
                // `CancellationError` on its own: a failed poll, not a stop.
                misses += 1
                if misses >= Self.staleAfterMisses { clear(host) }
            }
            do { try await dependencies.sleep(Self.intervalNanoseconds) } catch { return }
        }
    }

    private func cancelPoll(_ host: LeoHostID) {
        polls.removeValue(forKey: host)?.task.cancel()
    }

    private func clear(_ host: LeoHostID) {
        guard sampled.remove(host) != nil else { return }
        dependencies.deliver(nil, host)
    }

    /// One request, bounded by the request timeout. The request and the
    /// timer race as unattached tasks, so a request that ignores
    /// cancellation can't hold the poll past its timeout.
    private func sample(_ daemon: any LeoDaemonClient) async -> Outcome {
        let race = LeoStatsRace()
        let sleep = dependencies.sleep
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.attach(continuation)
                race.track([
                    Task { race.finish(await Self.request(daemon)) },
                    Task {
                        guard (try? await sleep(Self.requestTimeoutNanoseconds)) != nil else { return }
                        race.finish(.miss)
                    },
                ])
            }
        } onCancel: {
            race.finish(.cancelled)
        }
    }

    private nonisolated static func request(_ daemon: any LeoDaemonClient) async -> Outcome {
        do {
            return .stats(try await daemon.machineStats())
        } catch is CancellationError {
            return .cancelled
        } catch LeoDaemonError.daemon(let code, _, _) where isRefusal(code) {
            return .refused
        } catch {
            return .miss
        }
    }

    /// The daemon says stats won't come: it has none (503), or it refuses
    /// this device's token (401/403), which asking again can't fix.
    private nonisolated static func isRefusal(_ code: String?) -> Bool {
        guard let code else { return false }
        return [LeoMachineStats.unavailableCode, "unauthorized", "forbidden"].contains(code)
    }

    fileprivate enum Outcome: Sendable {
        case stats(LeoMachineStats)
        case refused
        case miss
        case cancelled
    }
}

/// Resolves to the first outcome offered, and cancels the tasks it tracks.
private final class LeoStatsRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LeoMachineStatsPoller.Outcome, Never>?
    private var outcome: LeoMachineStatsPoller.Outcome?
    private var tasks: [Task<Void, Never>] = []

    func attach(_ continuation: CheckedContinuation<LeoMachineStatsPoller.Outcome, Never>) {
        let ready = lock.withLock { () -> LeoMachineStatsPoller.Outcome? in
            if let outcome { return outcome }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func track(_ tasks: [Task<Void, Never>]) {
        let isDecided = lock.withLock { () -> Bool in
            if outcome != nil { return true }
            self.tasks = tasks
            return false
        }
        if isDecided { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: LeoMachineStatsPoller.Outcome) {
        let (waiting, losers) = lock.withLock { () -> (CheckedContinuation<LeoMachineStatsPoller.Outcome, Never>?, [Task<Void, Never>]) in
            guard outcome == nil else { return (nil, []) }
            outcome = result
            defer { continuation = nil; tasks = [] }
            return (continuation, tasks)
        }
        losers.forEach { $0.cancel() }
        waiting?.resume(returning: result)
    }
}
