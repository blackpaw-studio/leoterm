import Foundation

public protocol LeoPluginTimerHandle: Sendable {
    func cancel()
}

/// Where timers actually tick. Tests step it by hand.
public protocol LeoPluginTimerScheduling: Sendable {
    /// Calls `action` after `delay`, and then every `delay` when `repeating`.
    func schedule(after delay: TimeInterval, repeating: Bool, _ action: @escaping @Sendable () -> Void) -> any LeoPluginTimerHandle
}

public enum LeoPluginTimerError: Error, Equatable, LocalizedError, Sendable {
    case intervalTooShort(minimum: TimeInterval)
    case delayTooShort(minimum: TimeInterval)
    case tooManyTimers(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .intervalTooShort(let minimum): "timer interval must be at least \(Int(minimum)) s"
        case .delayTooShort(let minimum): "delay must be at least \(Int(minimum)) s"
        case .tooManyTimers(let limit): "a plugin can have at most \(limit) timers"
        }
    }
}

/// The timers of one plugin host (`leo.timer` and `leo.after`). Create one per
/// host and call ``stopAll()`` when the host stops.
///
/// - Periodic timers (≥ 60 s) fire for as long as the app runs.
/// - One-shots (`after`, ≥ 1 s) run only while one of the plugin's slots is
///   visible: one that elapses while none is waits and fires when a slot
///   becomes visible again.
public final class LeoPluginTimers: @unchecked Sendable {
    public static let minimumInterval: TimeInterval = 60
    public static let minimumDelay: TimeInterval = 1
    public static let maxTimers = 16

    private struct Entry {
        let generation: Int
        let handle: any LeoPluginTimerHandle
        let isOneShot: Bool
        var isHeld = false
    }

    private let scheduler: any LeoPluginTimerScheduling
    private let onFire: @Sendable (String) -> Void
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var nextGeneration = 0
    private var isSlotVisible = false

    public init(scheduler: any LeoPluginTimerScheduling, onFire: @escaping @Sendable (String) -> Void) {
        self.scheduler = scheduler
        self.onFire = onFire
    }

    public var activeIDs: [String] { lock.withLock { entries.keys.sorted() } }

    public func startPeriodic(id: String, seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds >= Self.minimumInterval else {
            throw LeoPluginTimerError.intervalTooShort(minimum: Self.minimumInterval)
        }
        try start(id: id, seconds: seconds, isOneShot: false)
    }

    public func startAfter(id: String, seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds >= Self.minimumDelay else {
            throw LeoPluginTimerError.delayTooShort(minimum: Self.minimumDelay)
        }
        try start(id: id, seconds: seconds, isOneShot: true)
    }

    public func stop(id: String) {
        let removed = lock.withLock { entries.removeValue(forKey: id) }
        removed?.handle.cancel()
    }

    public func stopAll() {
        let removed = lock.withLock { () -> [Entry] in
            defer { entries.removeAll() }
            return Array(entries.values)
        }
        removed.forEach { $0.handle.cancel() }
    }

    /// Tell the timers whether any of the plugin's slots is on screen.
    public func setSlotVisible(_ visible: Bool) {
        let due = lock.withLock { () -> [String] in
            isSlotVisible = visible
            guard visible else { return [] }
            let held = entries.filter { $0.value.isHeld }.map(\.key).sorted()
            held.forEach { entries.removeValue(forKey: $0) }
            return held
        }
        due.forEach(onFire)
    }

    // MARK: -

    private func start(id: String, seconds: TimeInterval, isOneShot: Bool) throws {
        let generation = try lock.withLock { () -> Int in
            guard entries[id] != nil || entries.count < Self.maxTimers else {
                throw LeoPluginTimerError.tooManyTimers(limit: Self.maxTimers)
            }
            nextGeneration += 1
            return nextGeneration
        }
        let handle = scheduler.schedule(after: seconds, repeating: !isOneShot) { [weak self] in
            self?.fire(id: id, generation: generation)
        }
        let replaced = lock.withLock { () -> Entry? in
            let old = entries[id]
            entries[id] = Entry(generation: generation, handle: handle, isOneShot: isOneShot)
            return old
        }
        replaced?.handle.cancel()
    }

    private func fire(id: String, generation: Int) {
        let shouldFire = lock.withLock { () -> Bool in
            guard var entry = entries[id], entry.generation == generation else { return false }
            guard entry.isOneShot else { return true }
            guard isSlotVisible else {
                entry.isHeld = true
                entries[id] = entry
                return false
            }
            entries.removeValue(forKey: id)
            return true
        }
        if shouldFire { onFire(id) }
    }
}

/// Real timers on a dispatch queue.
public struct LeoPluginDispatchTimerScheduler: LeoPluginTimerScheduling {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "studio.blackpaw.leo.plugin-timers")) {
        self.queue = queue
    }

    public func schedule(after delay: TimeInterval, repeating: Bool, _ action: @escaping @Sendable () -> Void) -> any LeoPluginTimerHandle {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay, repeating: repeating ? .seconds(Int(delay)) : .never, leeway: .milliseconds(250))
        source.setEventHandler(handler: action)
        source.resume()
        return DispatchHandle(source: source)
    }

    private final class DispatchHandle: LeoPluginTimerHandle, @unchecked Sendable {
        private let source: DispatchSourceTimer
        init(source: DispatchSourceTimer) { self.source = source }
        func cancel() { source.cancel() }
    }
}
