import Darwin
import Dispatch
import Foundation
import LeoKit
import os

/// How a host process ended.
enum LeoPluginHostTermination: Equatable, Sendable {
    /// Counts against the supervisor's crash budget. The reason is user-visible.
    case crashed(reason: String)
    /// `stop()` was called; not a crash.
    case stopped
}

/// The app's side of one plugin helper process: spawns it, speaks the framed
/// JSON wire protocol, runs the watchdog, and reports how it ended.
///
/// One connection is one process. After `onTermination` fires the object is
/// spent; the manager (which owns restart and backoff) makes a new one.
///
/// Threading: all state lives on a private serial `queue`. Socket reads run on
/// their own queue and writes on a third, so a large write can never stall
/// reading the helper's output (the helper would block on a full socket and
/// the two ends would deadlock). Callbacks run on `callbackQueue`.
final class LeoPluginHostConnection: @unchecked Sendable {
    struct Configuration {
        var pollInterval: TimeInterval = LeoPluginWatchdog.pollInterval
        var cpuBudgetSeconds: Double = LeoPluginWatchdog.cpuBudgetSeconds
        var memoryLimitBytes: UInt64 = LeoPluginWatchdog.memoryLimitBytes
        var memoryCheckInterval: TimeInterval = LeoPluginWatchdog.memoryCheckInterval
        var idleCPUBudgetSeconds: Double = LeoPluginWatchdog.idleCPUBudgetSeconds
        var idleCPUWindow: TimeInterval = LeoPluginWatchdog.idleCPUWindow
    }

    enum ConnectionError: Error, Equatable {
        case alreadyStarted
        case notRunning
    }

    private static let logger = Logger(subsystem: "studio.blackpaw.leo", category: "plugins")

    private let launcher: any LeoPluginHostLauncher
    private let readUsage: @Sendable (pid_t) -> LeoPluginUsage?
    private let clock: @Sendable () -> TimeInterval
    private let configuration: Configuration
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "leo.plugin.host.state")
    private let readQueue = DispatchQueue(label: "leo.plugin.host.read")
    private let writeQueue = DispatchQueue(label: "leo.plugin.host.write")

    /// Bridge requests from plugin code, in order. Set before `start`.
    var onRequest: (@Sendable (LeoPluginHostRequest) -> Void)?
    /// Called exactly once, after the process is gone.
    var onTermination: (@Sendable (LeoPluginHostTermination) -> Void)?

    // State, confined to `queue`.
    private var process: LeoPluginHostProcess?
    private var watchdog: LeoPluginWatchdog?
    private var pollTimer: DispatchSourceTimer?
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var pendingTermination: LeoPluginHostTermination?
    private var hasExited = false

    init(
        launcher: any LeoPluginHostLauncher,
        configuration: Configuration = Configuration(),
        readUsage: @escaping @Sendable (pid_t) -> LeoPluginUsage? = { LeoPluginProcessUsage.read(pid: $0) },
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        callbackQueue: DispatchQueue = .main
    ) {
        self.launcher = launcher
        self.configuration = configuration
        self.readUsage = readUsage
        self.clock = clock
        self.callbackQueue = callbackQueue
    }

    /// The helper's pid once started (for diagnostics and tests).
    var pid: pid_t? { queue.sync { process?.pid } }

    /// Spawns the helper and hands it the plugin's bundle. The app reads the
    /// JS bytes itself because the sandboxed helper can't read Application Support.
    func start(source: String) throws {
        try queue.sync {
            guard process == nil else { throw ConnectionError.alreadyStarted }
            let command = try Self.frame(.load(source: source))
            let launched = try launcher.launch()
            process = launched
            let pid = launched.pid
            watchdog = LeoPluginWatchdog(
                cpuBudgetSeconds: configuration.cpuBudgetSeconds,
                memoryLimitBytes: configuration.memoryLimitBytes,
                memoryCheckInterval: configuration.memoryCheckInterval,
                idleCPUBudgetSeconds: configuration.idleCPUBudgetSeconds,
                idleCPUWindow: configuration.idleCPUWindow,
                readUsage: { [readUsage] in readUsage(pid) })
            startExitSource(pid: pid)
            startReadSource(fd: launched.fd)
            startPolling()
            beginHandler()
            write(command, to: launched.fd)
        }
    }

    /// Delivers an app event to plugin code. Starts the CPU clock for its handler.
    func deliver(_ event: LeoPluginEvent) throws {
        try queue.sync {
            guard let process, !hasExited, pendingTermination == nil else { throw ConnectionError.notRunning }
            let command = try Self.frame(.deliver(event))
            beginHandler()
            write(command, to: process.fd)
        }
    }

    /// Kills the helper without counting a crash.
    func stop() {
        queue.async {
            guard !self.hasExited else { return }
            if self.pendingTermination == nil { self.pendingTermination = .stopped }
            self.killProcess()
        }
    }

    // MARK: Process lifecycle (on `queue`)

    private func startExitSource(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in self?.processExited() }
        exitSource = source
        source.resume()
    }

    private func startReadSource(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        var reader = LeoPluginFrameReader(limit: LeoPluginWire.maxHostToAppBytes)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        source.setEventHandler { [weak self] in
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
            guard count > 0 else {
                source.cancel()
                self?.queue.async { self?.socketEnded() }
                return
            }
            do {
                for frame in try reader.append(Data(chunk[0..<count])) {
                    let message = try LeoPluginHostMessage.decode(frame: frame)
                    self?.queue.async { self?.handle(message) }
                }
            } catch {
                source.cancel()
                self?.queue.async { self?.violation("\(error)") }
            }
        }
        // The descriptor is closed only after the process is reaped (see
        // `processExited`), never here: a write racing a close here could land
        // on a recycled descriptor.
        readSource = source
        source.resume()
    }

    private func handle(_ message: LeoPluginHostMessage) {
        guard !hasExited else { return }
        switch message {
        case .handlerDone:
            guard var dog = watchdog else { return }
            let verdict = dog.handlerFinished(at: clock())
            watchdog = dog
            apply(verdict)
        case .request(let request):
            callbackQueue.async { [weak self] in self?.onRequest?(request) }
        }
    }

    /// The socket closed or broke. A dead helper's EOF usually arrives before
    /// its exit event, so don't invent a reason here: the wait status in
    /// `processExited` says how it really ended. If the process is somehow
    /// still alive, end it.
    private func socketEnded() {
        guard !hasExited, pendingTermination == nil else { return }
        killProcess()
    }

    private func violation(_ detail: String) {
        guard !hasExited, pendingTermination == nil else { return }
        Self.logger.error("plugin host protocol violation: \(detail, privacy: .public)")
        pendingTermination = .crashed(reason: "host sent an invalid message (\(detail))")
        killProcess()
    }

    private func processExited() {
        guard !hasExited, let process else { return }
        hasExited = true
        var status: Int32 = 0
        waitpid(process.pid, &status, 0)  // reap: the exit source doesn't
        pollTimer?.cancel()
        pollTimer = nil
        exitSource?.cancel()
        exitSource = nil
        watchdog?.reset()
        readSource?.cancel()
        readSource = nil
        // Closing on the write queue waits out any write still in flight.
        writeQueue.async { close(process.fd) }
        let termination = pendingTermination ?? .crashed(reason: Self.describe(waitStatus: status))
        pendingTermination = termination
        callbackQueue.async { [weak self] in self?.onTermination?(termination) }
    }

    private func killProcess() {
        // `hasExited` flips on this queue right after `waitpid`, so a recycled
        // pid is never signalled.
        guard let process, !hasExited else { return }
        kill(process.pid, SIGKILL)
    }

    // MARK: Watchdog (on `queue`)

    /// Polls for the helper's whole life: the memory cap and the idle-CPU check
    /// apply between handlers too, not only while one is running.
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + configuration.pollInterval, repeating: configuration.pollInterval)
        timer.setEventHandler { [weak self] in self?.pollWatchdog() }
        pollTimer = timer
        timer.resume()
    }

    private func beginHandler() {
        watchdog?.handlerStarted(at: clock())
    }

    private func pollWatchdog() {
        guard !hasExited, pendingTermination == nil, var dog = watchdog else { return }
        let verdict = dog.poll(at: clock())
        watchdog = dog
        apply(verdict)
    }

    private func apply(_ verdict: LeoPluginWatchdogVerdict) {
        guard case .kill(let reason) = verdict, !hasExited, pendingTermination == nil else { return }
        Self.logger.error("plugin host killed: \(reason, privacy: .public)")
        pendingTermination = .crashed(reason: reason)
        killProcess()
    }

    // MARK: Wire

    private static func frame(_ command: LeoPluginHostCommand) throws -> Data {
        try LeoPluginWire.encode(JSONEncoder().encode(command), limit: LeoPluginWire.maxAppToHostBytes)
    }

    private func write(_ framed: Data, to fd: Int32) {
        writeQueue.async { [weak self] in
            do { try LeoPluginWire.writeAll(framed, to: fd) } catch {
                // The helper is gone or wedged; the exit source reports a death,
                // and a wedged one is bounded by the watchdog.
                Self.logger.debug("plugin host write failed: \(String(describing: error), privacy: .public)")
                self?.queue.async { self?.socketEnded() }
            }
        }
    }

    private static func describe(waitStatus status: Int32) -> String {
        let signalNumber = status & 0x7f
        if signalNumber == 0 { return "host exited with status \((status >> 8) & 0xff)" }
        return "host was killed by signal \(signalNumber)"
    }
}
