import Darwin
import Foundation

struct LeoUnixSocketTransport: LeoDaemonTransport {
    private let now: @Sendable () -> UInt64

    init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    func stream(path: String, socketPath: String, idleTimeout: TimeInterval = 60) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let descriptor = LeoSocketDescriptor()
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let request = LeoHTTPRequest(method: "GET", path: path).serialized()
                    try Self.streamBlocking(request, socketPath: socketPath, idleTimeout: idleTimeout,
                                            descriptor: descriptor, now: now) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: descriptor.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in descriptor.cancel(); task.cancel() }
        }
    }

    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else { throw LeoDaemonError.socketMissing(path: socketPath) }
        let descriptor = LeoSocketDescriptor()
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                return try await Task.detached(priority: .userInitiated) {
                    try Self.sendBlocking(request.serialized(), socketPath: socketPath, timeout: timeout, descriptor: descriptor)
                }.value
            } catch {
                if descriptor.isCancelled { throw CancellationError() }
                throw error
            }
        }, onCancel: { descriptor.cancel() })
    }

    private static func sendBlocking(_ wire: Data, socketPath: String, timeout: TimeInterval, descriptor: LeoSocketDescriptor) throws -> LeoHTTPResponse {
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw socketError() }
        descriptor.set(socketDescriptor)
        defer { descriptor.close() }
        var noSigPipe: Int32 = 1
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(socketDescriptor, F_GETFL)
        guard flags >= 0, fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw socketError() }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let limit = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard socketPath.utf8.count <= limit else { throw LeoDaemonError.transport("Socket path is too long") }
        _ = socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, limit)
            }
        }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw socketError() }
            try wait(socketDescriptor, events: Int16(POLLOUT), deadline: deadline, descriptor: descriptor)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socketDescriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { if error != 0 { errno = error }; throw socketError() }
        }
        var offset = 0
        while offset < wire.count {
            try wait(socketDescriptor, events: Int16(POLLOUT), deadline: deadline, descriptor: descriptor)
            let sent = wire.withUnsafeBytes { Darwin.send(socketDescriptor, $0.baseAddress?.advanced(by: offset), wire.count - offset, 0) }
            if sent > 0 { offset += sent; continue }
            guard sent < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw socketError() }
        }
        _ = Darwin.shutdown(socketDescriptor, SHUT_WR)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try wait(socketDescriptor, events: Int16(POLLIN), deadline: deadline, descriptor: descriptor)
            let count = Darwin.recv(socketDescriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            if count > 0 { data.append(contentsOf: buffer.prefix(Int(count))); continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { throw socketError() }
        }
        do { return try LeoHTTPResponse.parse(data) } catch { throw LeoDaemonError.transport("Incomplete or invalid HTTP response") }
    }

    private static func streamBlocking(_ wire: Data, socketPath: String, idleTimeout: TimeInterval,
                                       descriptor: LeoSocketDescriptor, now: @Sendable () -> UInt64,
                                       yield: (Data) -> Void) throws {
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw socketError() }
        descriptor.set(socketDescriptor)
        defer { descriptor.close() }
        var noSigPipe: Int32 = 1
        _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw socketError() }
        try wire.withUnsafeBytes { bytes in
            guard Darwin.send(socketDescriptor, bytes.baseAddress, bytes.count, 0) == bytes.count else { throw socketError() }
        }
        var pending = Data()
        var headersRead = false
        var chunked = false
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let instant = now()
            let deadline = instant + UInt64(idleTimeout * 1_000_000_000)
            try wait(socketDescriptor, events: Int16(POLLIN), deadline: deadline, descriptor: descriptor, now: now,
                     initialInstant: instant)
            let count = Darwin.recv(socketDescriptor, &buffer, buffer.count, 0)
            if count == 0 { return }
            guard count > 0 else { if errno == EINTR { continue }; throw socketError() }
            pending.append(contentsOf: buffer.prefix(Int(count)))
            if !headersRead {
                guard let separator = pending.range(of: Data("\r\n\r\n".utf8)) else { continue }
                guard let headers = String(bytes: pending[..<separator.lowerBound], encoding: .utf8)?.lowercased() else {
                    throw LeoDaemonError.decoding("HTTP headers are not UTF-8")
                }
                guard headers.hasPrefix("http/1.1 2") || headers.hasPrefix("http/1.0 2") else {
                    throw LeoDaemonError.transport("Events endpoint returned a non-success status")
                }
                chunked = headers.contains("transfer-encoding: chunked")
                pending.removeSubrange(..<separator.upperBound)
                headersRead = true
            }
            if chunked {
                while let chunk = try nextChunk(from: &pending) {
                    if !chunk.data.isEmpty { yield(chunk.data) }
                    if chunk.terminal { return }
                }
            } else if !pending.isEmpty {
                yield(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    private static func nextChunk(from data: inout Data) throws -> (data: Data, terminal: Bool)? {
        let crlf = Data("\r\n".utf8)
        guard let lineEnd = data.range(of: crlf) else { return nil }
        guard let line = String(data: data[..<lineEnd.lowerBound], encoding: .utf8),
              let size = Int(line.split(separator: ";")[0], radix: 16) else { throw LeoDaemonError.decoding("Invalid chunk size") }
        let start = lineEnd.upperBound
        guard let end = data.index(start, offsetBy: size, limitedBy: data.endIndex),
              data.distance(from: end, to: data.endIndex) >= 2 else { return nil }
        if size == 0 { data.removeAll(); return (Data(), true) }
        let result = Data(data[start..<end])
        data.removeSubrange(..<data.index(end, offsetBy: 2))
        return (result, false)
    }

    private static func wait(_ socketDescriptor: Int32, events: Int16, deadline: UInt64,
                             descriptor: LeoSocketDescriptor,
                             now: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                             initialInstant: UInt64? = nil) throws {
        var pendingInitialInstant = initialInstant
        while true {
            guard !descriptor.isCancelled else { throw CancellationError() }
            let instant: UInt64
            if let reused = pendingInitialInstant {
                instant = reused
                pendingInitialInstant = nil
            } else {
                instant = now()
            }
            guard instant < deadline else { throw LeoDaemonError.timeout }
            let milliseconds = min(50, Int32((deadline - instant + 999_999) / 1_000_000))
            var pollDescriptor = pollfd(fd: socketDescriptor, events: events, revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, milliseconds)
            guard !descriptor.isCancelled else { throw CancellationError() }
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                throw socketError()
            }
            if pollDescriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                if pollDescriptor.revents & Int16(POLLHUP) != 0, events == Int16(POLLIN) { return }
                throw socketError()
            }
            return
        }
    }

    private static func socketError() -> LeoDaemonError {
        if errno == EAGAIN || errno == EWOULDBLOCK { return .timeout }
        return .transport(String(cString: strerror(errno)))
    }
}

private final class LeoSocketDescriptor: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = -1
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func set(_ descriptor: Int32) { lock.lock(); defer { lock.unlock() }; if cancelled { _ = Darwin.close(descriptor); return }; value = descriptor }
    func cancel() { lock.lock(); cancelled = true; let descriptor = value; value = -1; lock.unlock(); if descriptor >= 0 { _ = Darwin.close(descriptor) } }
    func close() { lock.lock(); let descriptor = value; value = -1; lock.unlock(); if descriptor >= 0 { _ = Darwin.close(descriptor) } }
}
