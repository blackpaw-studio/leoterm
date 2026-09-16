import Darwin
import Foundation

@testable import Ghostty

struct FakeHubRequest: Equatable, Sendable {
    let method: String
    let path: String
    let body: Data
}

struct FakeHubScript: Sendable {
    var version: String? = "0.29.0"
    var legacyHealth = false
    var healthStatus = 200
    var hosts: [LeoHostRow] = [.init(name: "localhost", local: true, state: .local)]
    var agents: [String: [LeoAgent]] = [:]
    var templates: [String: [LeoTemplate]] = [:]
    var state: Data?
    var events: [String] = []
    var unavailableHosts: Set<String> = []
    var unknownHosts: Set<String> = []
}

actor FakeHubController {
    private var events: [String]
    private var closeEvents = false
    private var eventConnectionClosed = false

    init(events: [String] = []) { self.events = events }
    func inject(event: String) { events.append(event) }
    func ping() { events.append(": ping\n\n") }
    func close() { closeEvents = true }
    func takeEvents() -> [String] { defer { events.removeAll() }; return events }
    func shouldClose() -> Bool { closeEvents }
    func markEventConnectionClosed() { eventConnectionClosed = true }
    func didObserveEventConnectionClose() -> Bool { eventConnectionClosed }
}

/// Scriptable HTTP-over-unix-socket hub used by client and SSE tests.
final class FakeHubDaemon: @unchecked Sendable {
    let path: String
    let controller: FakeHubController
    private let listener: FakeHubListener
    private let storage = FakeHubStorage()

    init(script: FakeHubScript = .init(), onConnectionClosed: (@Sendable (Int32) -> Void)? = nil) throws {
        controller = FakeHubController(events: script.events)
        let socketPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("leo-hub-\(UUID().uuidString).sock").path
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.error() }
        unlink(socketPath)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                strncpy(UnsafeMutableRawPointer(target).assumingMemoryBound(to: CChar.self), source, capacity)
            }
        }
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0,
              listen(descriptor, 16) == 0 else { throw Self.error() }
        path = socketPath
        listener = FakeHubListener(path: socketPath, descriptor: descriptor, onClose: onConnectionClosed)

        // Each connection handler bundles only the immutable/independent
        // state it needs (script, controller, storage) instead of capturing
        // `self`. That decouples every handler's lifetime -- including a
        // long-lived SSE handler that blocks for the life of the connection
        // -- from the daemon instance's lifetime. If a handler retained
        // `self`, an open SSE connection would keep the daemon alive
        // forever, and `deinit` (the only thing that calls
        // `listener.shutdown()` to unblock that very connection) could never
        // run: a permanent deadlock between the handler and its own
        // teardown trigger.
        let handler = FakeHubConnectionHandler(script: script, controller: controller, storage: storage)
        let listener = listener
        DispatchQueue.global().async {
            listener.run { client in
                Task.detached {
                    defer { listener.closed(client) }
                    await handler.handle(client)
                }
            }
        }
    }

    deinit { listener.shutdown() }
    func requests() -> [FakeHubRequest] { storage.lock.withLock { storage.requests } }
    func shutdown() { listener.shutdown() }
    /// Number of connections the accept loop has registered so far. Lets a
    /// caller (e.g. a lifecycle test) synchronize on a client actually being
    /// accepted before acting on the daemon, instead of racing the
    /// background accept loop.
    func acceptedConnectionCount() -> Int { listener.acceptedCount() }

    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

/// Bundles the state a connection handler needs, independent of
/// `FakeHubDaemon`'s own identity/lifetime -- see the comment at the call
/// site in `FakeHubDaemon.init` for why that independence matters.
private struct FakeHubConnectionHandler: Sendable {
    let script: FakeHubScript
    let controller: FakeHubController
    let storage: FakeHubStorage

    func handle(_ client: Int32) async {
        guard let request = Self.readRequest(client) else { return }
        storage.lock.withLock { storage.requests.append(request) }
        if request.path == "/events" { await events(client); return }
        Self.send(client, response(for: request))
    }

    private func events(_ client: Int32) async {
        defer { Task { await controller.markEventConnectionClosed() } }
        Self.send(client, Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8))
        let version = script.version.map { "\"\($0)\"" } ?? "null"
        Self.send(client, Data("event: hello\ndata: {\"seq\":1,\"version\":\(version)}\n\n".utf8))
        for host in script.hosts {
            let state = switch host.state {
            case .local: "local"
            case .connecting: "connecting"
            case .connected: "connected"
            case .disconnected: "disconnected"
            case .error: "error"
            case .unknown(let value): value
            }
            var fields = ["\"host\":\"\(host.name)\"", "\"state\":\"\(state)\""]
            if let error = host.error { fields.append("\"error\":\"\(error)\"") }
            if let code = host.code { fields.append("\"code\":\"\(code)\"") }
            let row = "{" + fields.joined(separator: ",") + "}"
            Self.send(client, Data("event: host_state_changed\ndata: \(row)\n\n".utf8))
        }
        while !Task.isCancelled {
            var byte: UInt8 = 0
            let peek = Darwin.recv(client, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            // A graceful close reads 0. An abrupt close (e.g. the peer had
            // unread bytes buffered when it closed) surfaces as an error
            // other than "nothing available right now" -- treat that as
            // closed too, instead of looping on it forever.
            if peek == 0 { return }
            if peek < 0, errno != EAGAIN, errno != EWOULDBLOCK { return }
            for event in await controller.takeEvents() {
                guard Self.send(client, Data(event.utf8)) else { return }
            }
            if await controller.shouldClose() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func response(for request: FakeHubRequest) -> Data {
        let path = request.path
        let payload: Data
        if path == "/health" {
            if script.healthStatus != 200 { return http(script.healthStatus, json("{\"ok\":false,\"error\":\"failed\"}")) }
            if script.legacyHealth { payload = json("{\"ok\":true}")
            } else if let version = script.version { payload = json("{\"ok\":true,\"data\":{\"version\":\"\(version)\"}}")
            } else { payload = json("{\"ok\":true,\"data\":{}}") }
        } else if path == "/hosts" {
            payload = envelope(script.hosts)
        } else if path == "/state" {
            payload = script.state ?? json("{\"ok\":true,\"data\":{\"agents\":[]}}")
        } else if path.hasSuffix("/agents/list") {
            payload = envelope(script.agents[host(from: path)] ?? [LeoAgent]())
        } else if path.hasSuffix("/templates") {
            payload = envelope(script.templates[host(from: path)] ?? [LeoTemplate]())
        } else if path.hasSuffix("/connect") || path.hasSuffix("/disconnect") {
            payload = envelope(script.hosts.first { $0.name == host(from: path) } ?? .init(name: host(from: path), state: .disconnected))
        } else {
            payload = json("{\"ok\":true}")
        }
        if script.unknownHosts.contains(host(from: path)) { return http(404, json("{\"ok\":false,\"code\":\"host_unknown\",\"error\":\"unknown host\"}")) }
        if script.unavailableHosts.contains(host(from: path)) { return http(503, json("{\"ok\":false,\"code\":\"host_unavailable\",\"error\":\"offline\"}")) }
        return http(200, payload)
    }

    private func host(from path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1, parts[0] == "hosts" else { return "localhost" }
        return String(parts[1]).removingPercentEncoding ?? String(parts[1])
    }

    private func envelope<T: Encodable>(_ value: T) -> Data {
        let encoded = (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "null"
        return json("{\"ok\":true,\"data\":\(encoded)}")
    }
    private func json(_ value: String) -> Data { Data(value.utf8) }
    private func http(_ status: Int, _ body: Data) -> Data { Data("HTTP/1.1 \(status) OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body }

    private static func readRequest(_ client: Int32) -> FakeHubRequest? {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8),
              let first = head.split(separator: "\r\n").first else { return nil }
        let pieces = first.split(separator: " "); guard pieces.count > 1 else { return nil }
        return .init(method: String(pieces[0]), path: String(pieces[1]), body: Data(data[headerEnd.upperBound...]))
    }

    @discardableResult private static func send(_ client: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress?.advanced(by: offset), data.count - offset, 0) }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

private final class FakeHubStorage: @unchecked Sendable {
    let lock = NSLock()
    var requests: [FakeHubRequest] = []
}

/// Owns the listening socket and the set of accepted connection descriptors,
/// independent of `FakeHubDaemon`'s lifetime. Registration of a newly
/// accepted connection and `shutdown()`'s closing of every tracked
/// connection share the same lock, so a connection accepted concurrently
/// with `shutdown()` is either registered (and then closed by `shutdown()`)
/// or refused outright -- it can never be left untracked and leaked.
///
/// Close ownership is sole per connection: only `closed(_:)` -- called
/// exactly once by the handler that owns a given fd, in its `defer` -- ever
/// closes that fd. `shutdown()` never closes an accepted connection's fd
/// itself; it only signals (`shutdown(fd, SHUT_RDWR)`, which unblocks any
/// blocking/polling read on that fd without touching the fd's validity) and
/// then waits, bounded, for every outstanding handler to finish and call
/// `closed(_:)`. This prevents the fd-reuse hazard where the listener closes
/// an fd out from under its still-running handler, and the OS then hands
/// that same integer back out to a brand new, unrelated connection while the
/// old handler's (now dangling) `defer` closes it a second time.
private final class FakeHubListener: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let onClose: (@Sendable (Int32) -> Void)?
    private let lock = NSLock()
    private let handlerGroup = DispatchGroup()
    private var connections: Set<Int32> = []
    private var accepted = 0
    private var shutDown = false

    init(path: String, descriptor: Int32, onClose: (@Sendable (Int32) -> Void)? = nil) {
        self.path = path
        self.descriptor = descriptor
        self.onClose = onClose
    }

    /// Accepts connections until the listener is shut down, invoking
    /// `onAccept` for each one that is successfully registered. Does not
    /// capture or retain anything beyond this listener's own state.
    func run(onAccept: (Int32) -> Void) {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            let registered = lock.withLock { () -> Bool in
                guard !shutDown else { return false }
                connections.insert(client)
                accepted += 1
                return true
            }
            guard registered else {
                _ = Darwin.shutdown(client, SHUT_RDWR)
                _ = Darwin.close(client)
                continue
            }
            handlerGroup.enter()
            onAccept(client)
        }
    }

    func acceptedCount() -> Int { lock.withLock { accepted } }

    /// Sole closer of `client`'s fd. Called exactly once, by the handler
    /// that owns this connection, once it is completely done with it.
    func closed(_ client: Int32) {
        lock.withLock { _ = connections.remove(client) }
        _ = Darwin.close(client)
        onClose?(client)
        handlerGroup.leave()
    }

    func shutdown() {
        let connectionsToSignal = lock.withLock { () -> [Int32]? in
            guard !shutDown else { return nil }
            shutDown = true
            return Array(connections)
        }
        guard let connectionsToSignal else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = Darwin.close(descriptor)
        // Signal every open connection so its handler's blocking/polling
        // read observes EOF or an error and returns -- the handler alone
        // closes the fd afterward, via `closed(_:)`.
        connectionsToSignal.forEach { _ = Darwin.shutdown($0, SHUT_RDWR) }
        // Bounded wait for every handler to deregister and close its own fd,
        // so a caller relying on `shutdown()` having fully quiesced
        // connections doesn't race the handlers' teardown.
        _ = handlerGroup.wait(timeout: .now() + 5)
        unlink(path)
    }
}
