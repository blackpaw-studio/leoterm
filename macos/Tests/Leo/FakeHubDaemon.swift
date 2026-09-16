import Darwin
import Foundation

/// A one-connection scripted v0.29 daemon used by transport and SSE tests.
final class FakeHubDaemon: @unchecked Sendable {
    struct Script: Sendable {
        let status: Int
        let headers: [String: String]
        let chunks: [Data]

        init(status: Int = 200, headers: [String: String] = [:], chunks: [Data]) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
        }
    }

    let path: String
    private let server: UnixSocketTestServer
    private let storage: FakeHubStorage

    var request: Data { storage.lock.withLock { storage.request } }

    init(script: Script) throws {
        let storage = FakeHubStorage()
        self.storage = storage
        server = try UnixSocketTestServer { client in
            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count > 0 { storage.lock.withLock { storage.request.append(contentsOf: buffer.prefix(Int(count))) } }
            var response = Data("HTTP/1.1 \(script.status) OK\r\n".utf8)
            for (name, value) in script.headers { response.append(Data("\(name): \(value)\r\n".utf8)) }
            response.append(Data("\r\n".utf8))
            _ = response.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
            for chunk in script.chunks {
                _ = chunk.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
            }
        }
        path = server.path
    }

    func waitForRequest() -> Bool {
        let connected = server.waitForConnection()
        if connected { _ = server.waitForHandler() }
        return connected
    }
}

private final class FakeHubStorage: @unchecked Sendable {
    let lock = NSLock()
    var request = Data()
}
