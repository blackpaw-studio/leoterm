import Darwin
import Foundation

struct LeoUnixSocketTransport: LeoDaemonTransport {
    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw LeoDaemonError.socketMissing(path: socketPath)
        }
        return try await Task.detached(priority: .userInitiated) {
            try sendBlocking(request.serialized(), socketPath: socketPath, timeout: timeout)
        }.value
    }

    private func sendBlocking(_ wire: Data, socketPath: String, timeout: TimeInterval) throws -> LeoHTTPResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LeoDaemonError.transport(String(cString: strerror(errno))) }
        defer { close(descriptor) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeoutValue = timeval(
            tv_sec: __darwin_time_t(timeout),
            tv_usec: __darwin_suseconds_t((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard socketPath.utf8.count <= limit else { throw LeoDaemonError.transport("Socket path is too long") }
        _ = socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, limit)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw socketError() }

        var offset = 0
        while offset < wire.count {
            let sent = wire.withUnsafeBytes { buffer in
                Darwin.send(descriptor, buffer.baseAddress?.advanced(by: offset), wire.count - offset, 0)
            }
            guard sent > 0 else { throw socketError() }
            offset += sent
        }
        _ = Darwin.shutdown(descriptor, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw socketError() }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
        return try LeoHTTPResponse.parse(data)
    }

    private func socketError() -> LeoDaemonError {
        if errno == EAGAIN || errno == EWOULDBLOCK { return .timeout }
        return .transport(String(cString: strerror(errno)))
    }
}
