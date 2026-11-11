import Foundation

@testable import LeoKit

final class PluginFakeKeychain: LeoPluginKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [String: String] = [:]
    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }
    func get(service: String, account: String) throws -> String? { lock.withLock { items[key(service, account)] } }
    func set(service: String, account: String, value: String) throws { lock.withLock { items[key(service, account)] = value } }
    func delete(service: String, account: String) throws { lock.withLock { items[key(service, account)] = nil } }
    func deleteAll(service: String) throws {
        lock.withLock { items = items.filter { !$0.key.hasPrefix(service + "|") } }
    }
}

final class PluginFakeFetcher: LeoPluginFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<LeoPluginFetchResponse, Error>] = []
    private(set) var urls: [String] = []

    func enqueue(_ result: Result<LeoPluginFetchResponse, Error>) { lock.withLock { queued.append(result) } }

    func fetch(url: String, init options: LeoPluginFetchInit) async throws -> LeoPluginFetchResponse {
        let next = lock.withLock { () -> Result<LeoPluginFetchResponse, Error>? in
            urls.append(url)
            return queued.isEmpty ? nil : queued.removeFirst()
        }
        return try (next ?? .failure(LeoPluginFetchError.network("no response queued"))).get()
    }
}

@MainActor final class PluginFakeActions: LeoPluginActionRunning {
    private(set) var performed: [(LeoPluginAction, LeoPluginIdentity, LeoPluginSlotID?)] = []
    private(set) var confirmed: [(LeoPluginAction, LeoPluginIdentity)] = []
    func perform(_ action: LeoPluginAction, plugin: LeoPluginIdentity, slot: LeoPluginSlotID?) { performed.append((action, plugin, slot)) }
    func confirm(_ action: LeoPluginAction, plugin: LeoPluginIdentity) { confirmed.append((action, plugin)) }
}

/// Steps by hand: nothing fires until the test says so.
final class PluginManualScheduler: LeoPluginTimerScheduling, @unchecked Sendable {
    private final class Handle: LeoPluginTimerHandle, @unchecked Sendable {
        var isCancelled = false
        let delay: TimeInterval
        let action: @Sendable () -> Void
        init(delay: TimeInterval, action: @escaping @Sendable () -> Void) {
            self.delay = delay
            self.action = action
        }
        func cancel() { isCancelled = true }
    }

    private let lock = NSLock()
    private var handles: [Handle] = []

    func schedule(after delay: TimeInterval, repeating: Bool, _ action: @escaping @Sendable () -> Void) -> any LeoPluginTimerHandle {
        let handle = Handle(delay: delay, action: action)
        lock.withLock { handles.append(handle) }
        return handle
    }

    var liveDelays: [TimeInterval] { lock.withLock { handles.filter { !$0.isCancelled }.map(\.delay) } }

    /// Fires every live timer once.
    func fireAll() {
        let live = lock.withLock { handles.filter { !$0.isCancelled } }
        live.forEach { $0.action() }
    }
}

/// A fake helper process that records what the manager does to it.
final class PluginFakeHost: LeoPluginHosting, @unchecked Sendable {
    private let lock = NSLock()
    var onRequest: (@Sendable (LeoPluginHostRequest) -> Void)?
    var onTermination: (@Sendable (LeoPluginHostTermination) -> Void)?
    private var _source: String?
    private var _events: [LeoPluginEvent] = []
    private var _stopped = false
    var startError: Error?

    var source: String? { lock.withLock { _source } }
    var events: [LeoPluginEvent] { lock.withLock { _events } }
    var isStopped: Bool { lock.withLock { _stopped } }

    func start(source: String) throws {
        if let startError { throw startError }
        lock.withLock { _source = source }
    }

    func deliver(_ event: LeoPluginEvent) throws { lock.withLock { _events.append(event) } }

    func stop() {
        lock.withLock { _stopped = true }
        onTermination?(.stopped)
    }

    // Test drivers: what the helper would do.
    func send(_ request: LeoPluginHostRequest) { onRequest?(request) }
    func crash(_ reason: String = "boom") { onTermination?(.crashed(reason: reason)) }
}

final class PluginFakeHostFactory: LeoPluginHostMaking, @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [PluginFakeHost] = []
    var startError: Error?
    var made: [PluginFakeHost] { lock.withLock { _made } }
    var last: PluginFakeHost? { made.last }

    func makeHost() -> any LeoPluginHosting {
        let host = PluginFakeHost()
        host.startError = startError
        lock.withLock { _made.append(host) }
        return host
    }
}

final class PluginFakeTrash: LeoPluginTrashing, @unchecked Sendable {
    private let lock = NSLock()
    private var _trashed: [URL] = []
    var trashed: [URL] { lock.withLock { _trashed } }
    func moveToTrash(_ url: URL) throws {
        lock.withLock { _trashed.append(url) }
        try FileManager.default.removeItem(at: url)
    }
}

func gestureNow(_ at: Date = Date()) -> LeoPluginGesture { LeoPluginGesture(origin: .click, mintedAt: at) }
