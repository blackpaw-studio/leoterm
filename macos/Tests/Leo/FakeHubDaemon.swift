import Darwin
import Foundation

struct FakeHubRequest: Equatable, Sendable {
    let method: String
    let path: String
    let body: Data
}

struct FakeHubScript: Sendable {
    var version = "0.29.0"
    var hosts: [LeoHostRow] = [.init(name: "localhost", local: true, state: .local)]
    var agents: [String: [LeoAgent]] = [:]
    var templates: [String: [LeoTemplate]] = [:]
    var state: Data?
    var events: [String] = []
    var unavailableHosts: Set<String> = []
}

actor FakeHubController {
    private var events: [String]
    private var closeEvents = false

    init(events: [String] = []) { self.events = events }
    func inject(event: String) { events.append(event) }
    func ping() { events.append(": ping\n\n") }
    func close() { closeEvents = true }
    func takeEvents() -> [String] { defer { events.removeAll() }; return events }
    func shouldClose() -> Bool { closeEvents }
}

/// Scriptable HTTP-over-unix-socket hub used by client and SSE tests.
final class FakeHubDaemon: @unchecked Sendable {
    let path: String
    let controller: FakeHubController
    private let descriptor: Int32
    private let script: FakeHubScript
    private let storage = FakeHubStorage()

    init(script: FakeHubScript = .init()) throws {
        self.script = script
        controller = FakeHubController(events: script.events)
        path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("leo-hub-\(UUID().uuidString).sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.error() }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                strncpy(UnsafeMutableRawPointer(target).assumingMemoryBound(to: CChar.self), source, capacity)
            }
        }
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0,
              listen(descriptor, 16) == 0 else { throw Self.error() }
        DispatchQueue.global().async { [weak self] in self?.acceptLoop() }
    }

    deinit { _ = Darwin.close(descriptor); unlink(path) }
    func requests() -> [FakeHubRequest] { storage.lock.withLock { storage.requests } }

    private func acceptLoop() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            Task.detached { [weak self] in
                defer { _ = Darwin.close(client) }
                await self?.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) async {
        guard let request = Self.readRequest(client) else { return }
        storage.lock.withLock { storage.requests.append(request) }
        if request.path == "/events" { await events(client); return }
        Self.send(client, response(for: request))
    }

    private func events(_ client: Int32) async {
        Self.send(client, Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8))
        Self.send(client, Data("event: hello\ndata: {\"seq\":1,\"version\":\"\(script.version)\"}\n\n".utf8))
        for host in script.hosts {
            Self.send(client, Data("event: host_state_changed\ndata: {\"host\":\"\(host.name)\",\"state\":\"\(host.state.rawValue)\"}\n\n".utf8))
        }
        while !Task.isCancelled {
            for event in await controller.takeEvents() { Self.send(client, Data(event.utf8)) }
            if await controller.shouldClose() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func response(for request: FakeHubRequest) -> Data {
        let path = request.path
        let payload: Data
        if path == "/health" {
            payload = json("{\"ok\":true,\"version\":\"\(script.version)\"}")
        } else if path == "/hosts" {
            payload = envelope(script.hosts)
        } else if path == "/state" {
            payload = script.state ?? json("{\"agents\":[]}")
        } else if path.hasSuffix("/agents/list") {
            payload = envelope(script.agents[host(from: path)] ?? [])
        } else if path.hasSuffix("/templates") {
            payload = envelope(script.templates[host(from: path)] ?? [])
        } else if path.hasSuffix("/connect") || path.hasSuffix("/disconnect") {
            payload = envelope(script.hosts.first { $0.name == host(from: path) } ?? script.hosts[0])
        } else {
            payload = json("{\"ok\":true}")
        }
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

    private static func send(_ client: Int32, _ data: Data) { _ = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) } }
    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private final class FakeHubStorage: @unchecked Sendable { let lock = NSLock(); var requests: [FakeHubRequest] = [] }
