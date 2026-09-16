import Darwin
import Foundation
import Testing

@testable import Ghostty

/// `FakeHubListener.run()` used to register a newly accepted connection
/// (insert into `connections`, bump `accepted`) and only afterward call
/// `handlerGroup.enter()`, as two separate, unlocked steps. A `shutdown()`
/// racing in between could see the connection already in `connections` --
/// and so include it when signaling -- while `handlerGroup` was still empty,
/// call `wait()`, observe zero outstanding handlers, and return. The
/// connection's handler would then start (and run) *after* `shutdown()` had
/// already returned: the bounded-quiescence guarantee `shutdown()`'s doc
/// comment promises did not actually hold for a connection accepted in that
/// narrow window.
struct FakeHubDaemonAcceptRaceTests {
    @Test func shutdownRefusesAConnectionThatIsAcceptedButNotYetRegisteredAndItsHandlerNeverRuns() async throws {
        let recorder = CloseRecorder()
        let gate = SyncGate()
        var daemon: FakeHubDaemon? = try FakeHubDaemon(
            script: .init(),
            onConnectionClosed: { fd in Task { await recorder.record(fd) } },
            onConnectionAcceptedBeforeRegistration: {
                // Hold this connection here -- accepted by the OS, but not
                // yet inserted into `connections` or counted in
                // `handlerGroup` -- while the test races `shutdown()`
                // against it below.
                gate.signalAccepted()
                gate.waitForProceed()
            }
        )
        weak var weakDaemon = daemon
        let path = try #require(daemon?.path)

        let client = try Self.connect(to: path)
        defer { Darwin.close(client) }
        Self.send(client, "GET /health HTTP/1.1\r\nHost: fake\r\n\r\n")

        #expect(gate.waitForAccepted(timeout: .now() + 5), "Accept hook never fired for the test connection")

        // `shutdown()` runs to completion here with the connection still
        // held in the gate -- i.e. accepted, but deliberately unregistered.
        // It must return promptly (not hang waiting on a connection it
        // never counted), and it must leave `shutDown` set so the paused
        // connection is refused once released below.
        let start = DispatchTime.now()
        daemon?.shutdown()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        #expect(elapsed < 1, "shutdown() should return promptly when nothing is registered yet, not block for the full timeout")

        // Only now let the paused accept-loop thread proceed to the
        // registration check. It must observe `shutDown == true` and refuse
        // the connection outright rather than starting a handler for it.
        gate.proceed()

        await awaitCondition(timeout: 5, message: "Refused connection was never closed by the listener") {
            var byte: UInt8 = 0
            return Darwin.recv(client, &byte, 1, MSG_DONTWAIT) == 0
        }
        // Give any (incorrect) handler a moment to have run if it was going
        // to, then assert it never did.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(await recorder.count == 0, "No handler should ever run for a connection refused because shutdown had already begun")

        daemon = nil
        await awaitCondition(timeout: 5, message: "FakeHubDaemon never deinited after shutdown and dropping the last reference") {
            weakDaemon == nil
        }
    }

    /// The other half of the same guarantee: once registration (and
    /// `handlerGroup.enter()`) has succeeded for a connection, `shutdown()`
    /// must already be committed to waiting for it, even if the handler
    /// itself hasn't started running yet.
    @Test func shutdownWaitsForAConnectionThatFinishedRegisteringBeforeItsHandlerHadStarted() async throws {
        let handlerGate = SyncGate()
        let recorder = CloseRecorder()
        var daemon: FakeHubDaemon? = try FakeHubDaemon(
            script: .init(),
            onConnectionClosed: { fd in Task { await recorder.record(fd) } },
            onConnectionRegisteredBeforeHandlerStart: {
                // Registration and `handlerGroup.enter()` have already
                // happened atomically by this point; only the handler task
                // itself hasn't started. Hold here so the test can prove
                // `shutdown()` is already committed to waiting for it.
                handlerGate.signalAccepted()
                handlerGate.waitForProceed()
            }
        )
        let path = try #require(daemon?.path)

        let client = try Self.connect(to: path)
        defer { Darwin.close(client) }
        Self.send(client, "GET /health HTTP/1.1\r\nHost: fake\r\n\r\n")

        #expect(handlerGate.waitForAccepted(timeout: .now() + 5), "Registration hook never fired for the test connection")

        let shutdownReturned = Flag()
        let shutdownTask = Task {
            daemon?.shutdown()
            shutdownReturned.set()
        }

        // Give shutdown() a real chance to (wrongly) return early while the
        // registered-but-not-yet-started handler is still held.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!shutdownReturned.isSet, "shutdown() must not return while an already-registered connection's handler hasn't run yet")
        #expect(await recorder.count == 0)

        handlerGate.proceed()
        await shutdownTask.value

        #expect(shutdownReturned.isSet)
        #expect(await recorder.count == 1, "shutdown() must have waited for the handler to finish and close its connection")
    }

    /// Complements the gated test above with an ungated, real-world race:
    /// connect and shut down back to back, repeatedly, with no
    /// synchronization forcing a particular interleaving. Registration and
    /// `handlerGroup.enter()` being two separate unlocked steps (the
    /// original bug) made it *possible*, not guaranteed, for a handler to
    /// close its connection after `shutdown()` had already returned --
    /// repeating the race gives that possibility a real chance to surface.
    @Test func shutdownNeverObservesAHandlerCloseAfterItAlreadyReturnedAcrossManyRaces() async throws {
        for _ in 0..<50 {
            let shutdownReturned = Flag()
            let violation = Flag()
            var daemon: FakeHubDaemon? = try FakeHubDaemon(script: .init()) { _ in
                if shutdownReturned.isSet { violation.set() }
            }
            let path = try #require(daemon?.path)
            let client = try Self.connect(to: path)
            defer { Darwin.close(client) }
            Self.send(client, "GET /health HTTP/1.1\r\nHost: fake\r\n\r\n")

            daemon?.shutdown()
            shutdownReturned.set()

            // Give any straggling handler time to run and record a
            // violation before checking.
            try? await Task.sleep(nanoseconds: 20_000_000)
            #expect(!violation.isSet, "A handler's close callback fired after shutdown() had already returned")

            daemon = nil
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

    private static func send(_ client: Int32, _ text: String) {
        var data = Data(text.utf8)
        data.withUnsafeBytes { buffer in
            _ = Darwin.send(client, buffer.baseAddress, buffer.count, 0)
        }
    }
}

/// Synchronizes the test thread with the listener's background accept
/// thread: the accept thread signals once it has reached the gate, then
/// blocks until the test tells it to proceed.
private final class SyncGate: @unchecked Sendable {
    private let acceptedSemaphore = DispatchSemaphore(value: 0)
    private let proceedSemaphore = DispatchSemaphore(value: 0)

    func signalAccepted() { acceptedSemaphore.signal() }
    func waitForAccepted(timeout: DispatchTime) -> Bool { acceptedSemaphore.wait(timeout: timeout) == .success }
    func waitForProceed() { proceedSemaphore.wait() }
    func proceed() { proceedSemaphore.signal() }
}

private actor CloseRecorder {
    private var closeCounts: [Int32: Int] = [:]
    var count: Int { closeCounts.count }
    func record(_ fd: Int32) { closeCounts[fd, default: 0] += 1 }
}

/// A synchronously settable boolean, safe to flip and read from any thread
/// -- used where a callback must observe state set on another thread without
/// the scheduling latency of hopping through an actor.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
