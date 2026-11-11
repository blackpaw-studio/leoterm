import Darwin
import Dispatch
import Foundation
import LeoKit
import os

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
final class LeoPluginHostConnection: LeoPluginHosting, @unchecked Sendable {
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
    private var readThrottle: LeoPluginReadThrottle?
    private var exitSource: DispatchSourceProcess?
    private var pendingTermination: LeoPluginHostTermination?
    private var hasExited = false
    private var isReadSourceCancelled = false
    private var isDescriptorClosed = false

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

    /// Requests read from the helper but not yet delivered (for tests).
    var outstandingRequests: Int { queue.sync { readThrottle?.outstanding ?? 0 } }

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
        let throttle = LeoPluginReadThrottle(source: source)
        var reader = LeoPluginFrameReader(limit: LeoPluginWire.maxHostToAppBytes)
        var quota = LeoPluginRequestQuota()
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
                    if case .request = message {
                        if let reason = quota.record(requestBytes: frame.count) {
                            source.cancel()
                            self?.queue.async { self?.apply(.kill(reason: reason)) }
                            return
                        }
                        throttle.requestEnqueued()
                    } else {
                        quota.reset()
                    }
                    self?.queue.async { self?.handle(message) }
                }
            } catch {
                source.cancel()
                self?.queue.async { self?.violation("\(error)") }
            }
        }
        // The descriptor is closed only once the source's cancel handler has run
        // (so no `read` is in flight) and the process is reaped, never from the
        // event handler: see `closeDescriptorIfReady`.
        source.setCancelHandler {
            self.queue.async {
                self.isReadSourceCancelled = true
                self.closeDescriptorIfReady()
            }
        }
        readSource = source
        readThrottle = throttle
        source.resume()
    }

    private func handle(_ message: LeoPluginHostMessage) {
        switch message {
        case .handlerDone:
            guard !hasExited, var dog = watchdog else { return }
            let verdict = dog.handlerFinished(at: clock())
            watchdog = dog
            apply(verdict)
        case .request(let request):
            guard let throttle = readThrottle else { return }
            // Dropped, not delivered, once the helper is on its way out.
            guard !hasExited, !throttle.isClosed else { return throttle.requestFinished() }
            callbackQueue.async { [weak self] in
                defer { throttle.requestFinished() }
                guard !throttle.isClosed else { return }
                self?.onRequest?(request)
            }
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
        readThrottle?.close()
        readSource = nil
        closeDescriptorIfReady()
        let termination = pendingTermination ?? .crashed(reason: Self.describe(waitStatus: status))
        pendingTermination = termination
        callbackQueue.async { [weak self] in self?.onTermination?(termination) }
    }

    /// Closes the app's socket end once nothing can still use it: the process
    /// is reaped (no new writes), the read source's cancel handler has run (no
    /// read in flight), and, by queueing on the write queue, every write
    /// already issued has finished. Closing earlier could hit a recycled fd.
    private func closeDescriptorIfReady() {
        guard hasExited, isReadSourceCancelled, !isDescriptorClosed, let fd = process?.fd else { return }
        isDescriptorClosed = true
        writeQueue.async { close(fd) }
    }

    private func killProcess() {
        // `hasExited` flips on this queue right after `waitpid`, so a recycled
        // pid is never signalled.
        guard let process, !hasExited else { return }
        readThrottle?.close()  // stop reading; drop what is queued for the app
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
