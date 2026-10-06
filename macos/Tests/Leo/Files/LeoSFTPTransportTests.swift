import Foundation
import Testing

@testable import Ghostty

/// The SFTP session layer against the real macOS `sftp-server` and against
/// scripted fake servers that misbehave on cue.
struct LeoSFTPTransportTests {
    /// Production crosses an extra boundary the ordinary SFTP tests do not:
    /// `ssh` has to start the server on the other side of the existing
    /// ControlMaster. Some hosts expose `sftp-server` but intentionally have
    /// no sshd `Subsystem sftp` entry. The fake rejects subsystem requests,
    /// just like those hosts, while serving SFTP v3 for a fixed remote
    /// command.
    @Test func workspaceListingAndSurfacedReadsDoNotRequireTheSSHSubsystem() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.directory("workspace")
        let surfaced = try sandbox.file("workspace/result.txt", "done")
        let fakeSSH = try sandbox.file("ssh", """
            #!/bin/sh
            for argument in "$@"; do
              if [ "$argument" = "-s" ]; then
                echo 'subsystem request failed on channel 0' >&2
                exit 1
              fi
            done
            exec /usr/libexec/sftp-server -d %d
            """, permissions: 0o755)
        let command = LeoSSHCommand(configuration: .init(name: "work", sshTarget: "evan@work.example:2222", identityFile: "/keys/work"))
        let launcher = LeoCountingSFTPLauncher(
            LeoSFTPProcessLauncher(
                executable: URL(fileURLWithPath: fakeSSH),
                arguments: try command.sftpArguments(controlPath: "/tmp/leo-b233-control")
            )
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        let entries = try await access.list(sandbox.path("workspace"))
        let contents = try await access.read(surfaced, maxBytes: 1024)

        #expect(entries.map(\.name) == ["result.txt"])
        #expect(String(data: contents.data, encoding: .utf8) == "done")
        #expect(launcher.launches == 1, "the listing and surfaced-file read share one user-triggered SFTP session")
        await access.close()
    }

    @Test func anUnavailableSFTPServerIsActionableAndLaunchesOnlyOnce() async throws {
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script("echo 'leo: no supported sftp-server found' >&2; exit 127"))
        let access = LeoFileAccessor.sftp(launcher: launcher)

        let expected = LeoFileAccessError.unavailable(
            reason: "no supported SFTP server was found on the host (status 127). Install the host’s OpenSSH server package, then try again"
        )
        await #expect(throws: expected) { try await access.list("/") }
        #expect(launcher.launches == 1)
        await access.close()
    }

    @Test func anSSHSetupFailureIsStillDisconnected() async throws {
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script("echo 'control master is gone' >&2; exit 255"))
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1)
        await access.close()
    }

    @Test func aServiceStartupFailureKeepsBoundedSanitizedContext() async throws {
        let detail = "first line\\n" + String(repeating: "x", count: 500)
        let launcher = LeoSFTPTestServer.script("printf '\(detail)' >&2; exit 42")
        let access = LeoFileAccessor.sftp(launcher: launcher)

        do {
            _ = try await access.stat("/")
            Issue.record("the failed service unexpectedly completed an SFTP handshake")
        } catch let error as LeoFileAccessError {
            #expect(error.localizedDescription.contains("status 42"))
            #expect(!error.localizedDescription.contains("\n"))
            #expect(error.localizedDescription.contains("…"))
            #expect(error.localizedDescription.count < 350)
        }
        await access.close()
    }

    @Test func handshakeNegotiatesVersionThreeAndSeesPosixRename() async throws {
        let transport = LeoSFTPTransport(channel: try LeoSFTPTestServer.launcher().launch())
        defer { transport.close() }

        let version = try await transport.handshake()

        #expect(version.version == 3)
        #expect(version.supportsPosixRename)
    }

    @Test func pipelinedRequestsAreMatchedToTheirReplies() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let paths = try (0..<40).map { try sandbox.file("f\($0)", String(repeating: "x", count: $0)) }
        let access = LeoFileAccessor.sftp(launcher: LeoSFTPTestServer.launcher())

        let sizes = try await withThrowingTaskGroup(of: (Int, UInt64).self) { group in
            for (index, path) in paths.enumerated() {
                group.addTask { (index, try await access.stat(path).size) }
            }
            return try await group.reduce(into: [Int: UInt64]()) { $0[$1.0] = $1.1 }
        }
        await access.close()

        #expect(sizes == Dictionary(uniqueKeysWithValues: (0..<40).map { ($0, UInt64($0)) }))
    }

    @Test func aServerThatExitsBeforeReplyingIsDisconnected() async throws {
        let transport = LeoSFTPTransport(channel: try LeoSFTPTestServer.script("exit 0").launch())
        defer { transport.close() }

        await #expect(throws: LeoFileAccessError.disconnected) { try await transport.handshake() }
        await #expect(throws: LeoFileAccessError.disconnected) { try await transport.send(.stat(path: "/")) }
    }

    @Test func aServerThatExitsWithARequestInFlightIsDisconnected() async throws {
        // Swallows INIT, answers VERSION, reads one byte of the next request, exits.
        let script = "head -c 9 >/dev/null; \(LeoSFTPTestServer.versionReply); head -c 1 >/dev/null"
        let transport = LeoSFTPTransport(channel: try LeoSFTPTestServer.script(script).launch())
        defer { transport.close() }

        _ = try await transport.handshake()

        await #expect(throws: LeoFileAccessError.disconnected) { try await transport.send(.stat(path: "/")) }
        #expect(transport.isClosed)
    }

    @Test func malformedServerOutputIsAProtocolError() async throws {
        // A valid VERSION followed by a reply of a request type (OPEN).
        let script = "head -c 9 >/dev/null; printf '\\000\\000\\000\\005\\002\\000\\000\\000\\003\\000\\000\\000\\005\\003\\000\\000\\000\\001'; exec sleep 5"
        let transport = LeoSFTPTransport(channel: try LeoSFTPTestServer.script(script).launch())
        defer { transport.close() }

        _ = try await transport.handshake()

        await #expect(throws: LeoFileAccessError.protocolError("unexpected packet type 3")) {
            try await transport.send(.stat(path: "/"))
        }
    }

    @Test func closeFailsPendingRequestsAndStopsTheServer() async throws {
        let script = "head -c 9 >/dev/null; \(LeoSFTPTestServer.versionReply); exec sleep 5"
        let transport = LeoSFTPTransport(channel: try LeoSFTPTestServer.script(script).launch())
        _ = try await transport.handshake()

        let reply = Task { try await transport.send(.stat(path: "/")) }
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.close()

        await #expect(throws: LeoFileAccessError.disconnected) { try await reply.value }
        #expect(transport.isClosed)
    }

    @Test func aLocalLaunchFailureIsUnavailable() async throws {
        let launcher = LeoSFTPProcessLauncher(executable: URL(fileURLWithPath: "/nonexistent/sftp-server"), arguments: [])
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.unavailable(reason: "the SFTP process couldn’t start")) {
            try await access.stat("/")
        }
    }

    @Test func eachOperationAfterADisconnectMakesExactlyOneFreshAttempt() async throws {
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script("exit 0"))
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1)
        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 2)
    }

    /// Closing is final: a later call fails as closed and never
    /// reconnects.
    @Test func oneSessionServesManyOperationsAndNeverReopensAfterClose() async throws {
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.launcher())
        let access = LeoFileAccessor.sftp(launcher: launcher)

        _ = try await access.stat("/")
        _ = try await access.list("/")
        #expect(launcher.launches == 1)

        await access.close()
        await #expect(throws: LeoFileAccessError.closed) { try await access.stat("/") }
        await #expect(throws: LeoFileAccessError.closed) { try await access.list("/") }
        #expect(launcher.launches == 1)
    }

    /// A server that never answers holds nothing up: closing returns at
    /// once, whether the request is stuck in the handshake or after it,
    /// and what's in flight fails as closed.
    @Test(.timeLimit(.minutes(1)), arguments: ["exec sleep 30", "head -c 9 >/dev/null; \(LeoSFTPTestServer.versionReply); exec sleep 30"])
    func closingDuringAHungRequestReturnsAtOnceAndFailsItAsClosed(_ script: String) async throws {
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script(script))
        let access = LeoFileAccessor.sftp(launcher: launcher)
        let request = Task { try await access.stat("/") }
        while launcher.launches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))

        let closing = Task { await access.close() }
        let started = ContinuousClock.now
        try await eventuallyDone(closing, within: .seconds(2))

        #expect(ContinuousClock.now - started < .seconds(2))
        await #expect(throws: LeoFileAccessError.closed) { try await request.value }
        #expect(launcher.launches == 1)
    }

    private func eventuallyDone(_ task: Task<Void, Never>, within limit: Duration) async throws {
        let done = LeoDoneFlag()
        Task {
            await task.value
            done.set()
        }
        let deadline = ContinuousClock.now + limit
        while !done.isSet, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(done.isSet, "close() is still waiting")
    }

    @Test func unsupportedServerVersionsAreRefused() async throws {
        // VERSION 2.
        let script = "head -c 9 >/dev/null; printf '\\000\\000\\000\\005\\002\\000\\000\\000\\002'; exec sleep 5"
        let access = LeoFileAccessor.sftp(launcher: LeoSFTPTestServer.script(script))

        await #expect(throws: LeoFileAccessError.protocolError("server speaks SFTP v2, not v3")) { try await access.stat("/") }
        await access.close()
    }
}

final class LeoDoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isSet: Bool { lock.withLock { done } }
    func set() { lock.withLock { done = true } }
}
