import Darwin
import Foundation
import Testing

@testable import Ghostty

/// `FakeHubDaemon`'s accept loop used to run as `self?.acceptLoop()` on a
/// background queue. That syntax loads the weak reference into a strong local
/// for the duration of the call -- and since `acceptLoop()` blocks in
/// `accept()` until the listening socket is closed, it retained the daemon
/// for the entire lifetime of the loop. Since only `shutdown()` (called from
/// `deinit`) closes that socket, and `deinit` can never run while something
/// still holds a strong reference, dropping the last external reference
/// could never trigger cleanup: a permanent retain cycle through the
/// dispatch queue.
struct FakeHubDaemonLifecycleTests {
    @Test func droppingTheLastReferenceDeinitsTheDaemonAndClosesConnectedClients() async throws {
        var daemon: FakeHubDaemon? = try FakeHubDaemon()
        weak var weakDaemon = daemon
        let path = try #require(daemon?.path)

        let client = try Self.connect(to: path)
        defer { Darwin.close(client) }

        // Synchronize on the listener having actually accepted and
        // registered this connection before dropping the daemon reference.
        // `connect()` returning only means the kernel queued the connection;
        // the background accept loop may not have picked it up yet. Racing
        // that with `daemon = nil` below would make the EOF assertion
        // flaky -- the daemon could deinit and shut the listener down before
        // the connection was ever registered as one it owns.
        await awaitCondition(timeout: 5, message: "Listener never accepted the test client") {
            (daemon?.acceptedConnectionCount() ?? 0) >= 1
        }

        // Drop the only external strong reference without calling shutdown()
        // explicitly. If the accept loop still retains the daemon for its
        // lifetime, this will never deinit.
        daemon = nil

        await awaitCondition(timeout: 5, message: "FakeHubDaemon never deinited after its last strong reference was dropped") {
            weakDaemon == nil
        }

        await awaitCondition(timeout: 5, message: "Connected client never observed EOF after the daemon deinited") {
            var byte: UInt8 = 0
            let count = Darwin.recv(client, &byte, 1, MSG_DONTWAIT)
            return count == 0
        }
    }

    private static func connect(to path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                strncpy(UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), source, capacity)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return descriptor
    }
}
