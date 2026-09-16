import Darwin
import Foundation

final class UnixSocketTestServer: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let accepted = DispatchSemaphore(value: 0)
    private let closed = DispatchSemaphore(value: 0)

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
        DispatchQueue.global().async { [self] in
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

    private static func error() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
