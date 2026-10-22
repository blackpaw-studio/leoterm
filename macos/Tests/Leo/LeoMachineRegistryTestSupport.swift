import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// A scripted `LeoTunnelProcess`: no process and no socket. The test decides
/// when it is ready, when it dies, and how long its teardown takes.
final class LeoFakeTunnel: LeoTunnelProcess, @unchecked Sendable {
    enum Readiness: Sendable {
        /// `start()` returns at once.
        case ready
        /// `start()` throws as if ssh exited before the socket answered.
        case fails(String)
        /// `start()` parks until the tunnel exits or is torn down.
        case hangs
        /// `start()` parks until `open()`, and teardown does not release it:
        /// a health probe that answers after the tunnel was superseded.
        case gated
    }

    let launch: LeoTunnelLaunch
    let fakePID: Int32
    private let readiness: Readiness
    private let teardown: @Sendable () -> Void
    private let lock = NSLock()
    private var launchCallback: (@Sendable (Int32, TimeInterval) -> Void)?
    private var exitCallback: (@Sendable (LeoTunnelExit) -> Void)?
    private var exited = false
    private var terminations = 0
    private var parkedStart: CheckedContinuation<Void, Error>?
    private var isOpen = false

    init(launch: LeoTunnelLaunch, pid: Int32, readiness: Readiness, teardown: @escaping @Sendable () -> Void) {
        self.launch = launch
        fakePID = pid
        self.readiness = readiness
        self.teardown = teardown
    }

    var onLaunch: (@Sendable (Int32, TimeInterval) -> Void)? {
        get { lock.withLock { launchCallback } }
        set { lock.withLock { launchCallback = newValue } }
    }

    var onExit: (@Sendable (LeoTunnelExit) -> Void)? {
        get { lock.withLock { exitCallback } }
        set { lock.withLock { exitCallback = newValue } }
    }

    var pid: Int32? { fakePID }
    var hasExited: Bool { lock.withLock { exited } }
    var terminationCount: Int { lock.withLock { terminations } }
    var startTime: TimeInterval { TimeInterval(fakePID) }

    func start() async throws {
        onLaunch?(fakePID, startTime)
        switch readiness {
        case .ready:
            return
        case .fails(let tail):
            lock.withLock { exited = true }
            throw LeoTunnelError.exitedBeforeReady(status: 255, stderrTail: tail)
        case .hangs, .gated:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome = lock.withLock { () -> Result<Void, Error>? in
                    if isOpen { return .success(()) }
                    if case .hangs = readiness, exited { return .failure(LeoTunnelError.notReady(stderrTail: "")) }
                    parkedStart = continuation
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        }
    }

    /// Lets a `.gated` start succeed.
    func open() {
        let parked = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            isOpen = true
            defer { parkedStart = nil }
            return parkedStart
        }
        parked?.resume()
    }

    func terminateAndWait() {
        lock.withLock { terminations += 1 }
        teardown()
        let parked = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            exited = true
            guard case .hangs = readiness else { return nil }
            defer { parkedStart = nil }
            return parkedStart
        }
        parked?.resume(throwing: LeoTunnelError.notReady(stderrTail: ""))
    }

    /// The ssh process dies on its own: a parked start fails, then `onExit` fires.
    func exit(status: Int32 = 255, stderr: String = "") {
        let (parked, callback) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, (@Sendable (LeoTunnelExit) -> Void)?) in
            exited = true
            defer { parkedStart = nil }
            return (parkedStart, exitCallback)
        }
        parked?.resume(throwing: LeoTunnelError.exitedBeforeReady(status: status, stderrTail: stderr))
        callback?(LeoTunnelExit(status: status, stderrTail: stderr))
    }
}

/// The tunnel factory tests inject: scripts each machine's tunnels by ssh
/// target and keeps every tunnel it made, in order.
final class LeoFakeTunnels: @unchecked Sendable {
    private let lock = NSLock()
    private var readiness: [String: [LeoFakeTunnel.Readiness]] = [:]
    private var teardowns: [String: @Sendable () -> Void] = [:]
    private var made: [LeoFakeTunnel] = []
    private var launchObservers: [@Sendable (LeoFakeTunnel, [LeoFakeTunnel]) -> Void] = []
    private var nextPID: Int32 = 40_000

    /// Each new tunnel for `target` takes the next readiness; the last one repeats.
    func script(_ target: String, _ sequence: LeoFakeTunnel.Readiness...) {
        lock.withLock { readiness[target] = sequence }
    }

    /// Runs inside `target`'s `terminateAndWait()`, e.g. to block it.
    func onTeardown(_ target: String, _ block: @escaping @Sendable () -> Void) {
        lock.withLock { teardowns[target] = block }
    }

    /// Called as each tunnel is made, with every tunnel made before it.
    func onMake(_ observer: @escaping @Sendable (_ made: LeoFakeTunnel, _ earlier: [LeoFakeTunnel]) -> Void) {
        lock.withLock { launchObservers.append(observer) }
    }

    func tunnels(_ target: String) -> [LeoFakeTunnel] {
        lock.withLock { made.filter { $0.launch.arguments.contains(target) } }
    }

    var all: [LeoFakeTunnel] { lock.withLock { made } }

    var factory: LeoTunnelFactory {
        { [self] launch in make(launch) }
    }

    private func make(_ launch: LeoTunnelLaunch) -> any LeoTunnelProcess {
        let (tunnel, earlier, observers) = lock.withLock { () -> (LeoFakeTunnel, [LeoFakeTunnel], [@Sendable (LeoFakeTunnel, [LeoFakeTunnel]) -> Void]) in
            let target = readiness.keys.first { launch.arguments.contains($0) }
            let queue = target.flatMap { readiness[$0] } ?? [.ready]
            if let target, queue.count > 1 { readiness[target] = Array(queue.dropFirst()) }
            let teardown = teardowns.first { launch.arguments.contains($0.key) }?.value ?? {}
            nextPID += 1
            let tunnel = LeoFakeTunnel(launch: launch, pid: nextPID, readiness: queue.first ?? .ready, teardown: teardown)
            let earlier = made
            made.append(tunnel)
            return (tunnel, earlier, launchObservers)
        }
        observers.forEach { $0(tunnel, earlier) }
        return tunnel
    }
}

/// The registry's injected sleep: records every requested delay in order and
/// holds it until the test fires it. A cancelled sleep leaves at once.
final class LeoManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedDelays: [Duration] = []
    private var sleepers: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancelledEarly: Set<Int> = []
    private var nextID = 0

    var requested: [Duration] { lock.withLock { requestedDelays } }
    var pendingCount: Int { lock.withLock { sleepers.count } }

    func sleep(_ delay: Duration) async throws {
        let id = lock.withLock { () -> Int in
            requestedDelays.append(delay)
            defer { nextID += 1 }
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if cancelledEarly.remove(id) != nil { return true }
                    sleepers[id] = continuation
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let sleeper = sleepers.removeValue(forKey: id) else { cancelledEarly.insert(id); return nil }
                return sleeper
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    /// Wakes every pending sleep.
    func fireAll() {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            defer { sleepers = [:] }
            return Array(sleepers.values)
        }
        due.forEach { $0.resume() }
    }
}

/// Resolves `~/` for every machine but `hangingTarget`, whose ssh never
/// answers until `release()`.
actor LeoHangingHomeRunner: LeoProcessRunning {
    let hangingTarget: String
    private var parked: [CheckedContinuation<Void, Never>] = []
    private(set) var hungCalls = 0

    init(hangingTarget: String) { self.hangingTarget = hangingTarget }

    func run(executable _: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        guard arguments.contains(hangingTarget) else {
            return LeoProcessResult(stdout: Data("/home/evan".utf8), stderr: Data(), status: 0)
        }
        hungCalls += 1
        await withCheckedContinuation { parked.append($0) }
        return LeoProcessResult(stdout: Data(), stderr: Data("timed out".utf8), status: 255)
    }

    func release() {
        parked.forEach { $0.resume() }
        parked = []
    }
}

/// A thread-safe list a fake's callbacks (run off the main actor) append to.
final class LeoLockedLog<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element] = []

    func append(_ element: Element) { lock.withLock { elements.append(element) } }
    var values: [Element] { lock.withLock { elements } }
}

enum LeoMachineRegistryTestSupport {
    static func environment(
        defaults: UserDefaults,
        tunnels: LeoFakeTunnels,
        runner: any LeoProcessRunning = LeoFakeHomeRunner(stdout: "/home/evan"),
        orphanStore: LeoTunnelOrphanStore? = nil
    ) -> LeoMachineConnectionEnvironment {
        let directory = LeoHostSelectionTestSupport.localSocketDirectory
        return LeoMachineConnectionEnvironment(
            orphanStore: orphanStore ?? LeoTunnelOrphanStore(defaults: defaults, legacySocketDirectory: directory),
            runner: runner,
            sshExecutable: LeoTunnelTestSupport.fixtureURL(),
            transport: LeoAlwaysHealthyTransport(),
            localSocketPath: LeoHostSelectionTestSupport.localSocketPath,
            legacySocketDirectory: directory,
            controlSocketDirectory: directory,
            makeTunnel: tunnels.factory
        )
    }

    static func save(_ hosts: [LeoHostConfiguration], to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(hosts), forKey: LeoHostStore.key)
    }

    /// The same name always gives the same id, so saving a machine again
    /// unchanged is not an edit. Distinct in the leading 12 hex digits,
    /// which name the machine's sockets.
    static func host(_ name: String, enabled: Bool = true, remoteSocketPath: String = "/remote/leo.sock") -> LeoHostConfiguration {
        LeoHostConfiguration(id: stableID(name), name: name, sshTarget: "evan@\(name)", remoteSocketPath: remoteSocketPath, isEnabled: enabled)
    }

    private static func stableID(_ name: String) -> UUID {
        let hash = name.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        let hex = String(format: "%012llx", hash & 0xFFFF_FFFF_FFFF)
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.suffix(4))-4000-8000-000000000000") ?? UUID()
    }

    static func isConnected(_ state: LeoHostConnectionState?) -> Bool {
        if case .connected = state { return true }
        return false
    }

    static func isFailed(_ state: LeoHostConnectionState?) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

extension LeoMachineRegistry {
    /// A registry on its own in-memory defaults (or `defaults`) whose remote
    /// machines run fake tunnels: nothing here ever launches ssh, and its
    /// sockets live in the shared test directory (B-032).
    @MainActor static func isolatedForTesting(
        defaults: UserDefaults? = nil,
        tunnels: LeoFakeTunnels = LeoFakeTunnels(),
        runner: any LeoProcessRunning = LeoFakeHomeRunner(stdout: "/home/evan"),
        orphanStore: LeoTunnelOrphanStore? = nil,
        sleeper: LeoManualSleeper = LeoManualSleeper(),
        activationCenter: NotificationCenter = NotificationCenter(),
        waitForTeardown: @escaping TeardownWait = LeoMachineRegistry.blockingWait,
        connectionTarget: @escaping (LeoHostID, Int, LeoHostConnectionState) -> Void = { _, _, _ in }
    ) -> LeoMachineRegistry {
        let defaults = defaults ?? LeoInMemoryDefaults()
        return LeoMachineRegistry(
            store: LeoHostStore(defaults: defaults),
            environment: LeoMachineRegistryTestSupport.environment(defaults: defaults, tunnels: tunnels, runner: runner, orphanStore: orphanStore),
            sleep: { try await sleeper.sleep($0) },
            activationCenter: activationCenter,
            waitForTeardown: waitForTeardown,
            connectionTarget: connectionTarget
        )
    }
}
