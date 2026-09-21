import Darwin
import Foundation

final class UnixSocketTestServer: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let accepted = DispatchSemaphore(value: 0)
    private let closed = DispatchSemaphore(value: 0)
    private let handlerGroup = DispatchGroup()

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("leo-test-\(UUID().uuidString).sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketTestServer.error() }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, pathCapacity)
            }
        }
        guard copied != nil else { throw UnixSocketTestServer.error() }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else { throw UnixSocketTestServer.error() }
        handlerGroup.enter()
        DispatchQueue.global().async { [self] in
            defer { handlerGroup.leave() }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            accepted.signal()
            handler(client)
            _ = Darwin.close(client)
            closed.signal()
        }
    }

    deinit {
        _ = Darwin.close(descriptor)
        unlink(path)
    }

    func waitForConnection() -> Bool { accepted.wait(timeout: .now() + 1) == .success }
    func waitForClose() -> Bool { closed.wait(timeout: .now() + 1) == .success }
    func waitForHandler(timeout: TimeInterval = 1) -> Bool { handlerGroup.wait(timeout: .now() + timeout) == .success }

    private static func error() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

/// Like `UnixSocketTestServer`, but accepts an unbounded number of
/// concurrent connections (each handled on its own queue) instead of
/// exactly one -- for exercising a transport under concurrent load.
final class ConcurrentUnixSocketServer: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let handlerGroup = DispatchGroup()
    private let lock = NSLock()
    private var closed = false

    init(handler: @escaping @Sendable (Int32) -> Void) throws {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("leo-test-\(UUID().uuidString).sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ConcurrentUnixSocketServer.error() }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        let copied = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, pathCapacity)
            }
        }
        guard copied != nil else { throw ConcurrentUnixSocketServer.error() }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 64) == 0 else { throw ConcurrentUnixSocketServer.error() }
        DispatchQueue.global().async { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                handlerGroup.enter()
                DispatchQueue.global().async {
                    handler(client)
                    _ = Darwin.close(client)
                    self.handlerGroup.leave()
                }
            }
        }
    }

    deinit {
        closeOnce()
        unlink(path)
    }

    /// Stops accepting new connections and waits for in-flight handlers to
    /// finish. `shutdown(SHUT_RDWR)` breaks the blocking `accept()` loop;
    /// the actual `close()` only happens once (guarded by `closed`) since
    /// closing an fd a second time -- e.g. once here and again from
    /// `deinit`, or concurrently from both -- risks closing an unrelated fd
    /// the kernel has since reused for one of the up-to-20 concurrent
    /// client connections this server handles.
    func stop(timeout: TimeInterval = 2) {
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        _ = handlerGroup.wait(timeout: .now() + timeout)
        closeOnce()
        unlink(path)
    }

    private func closeOnce() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        _ = Darwin.close(descriptor)
    }

    private static func error() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
