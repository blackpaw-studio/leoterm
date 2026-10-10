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
    @Test func aWorkingSubsystemUsesOneProcessForListingAndSurfacedReads() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.directory("workspace")
        let surfaced = try sandbox.file("workspace/result.txt", "done")
        let fakeSSH = try sandbox.file("ssh", """
            #!/bin/sh
            for argument in "$@"; do
              if [ "$argument" = "-s" ]; then
                exec /usr/libexec/sftp-server -d %d
              fi
            done
            echo 'expected the sftp subsystem' >&2
            exit 42
            """, permissions: 0o755)
        let command = LeoSSHCommand(configuration: .init(name: "work", sshTarget: "evan@work.example:2222", identityFile: "/keys/work"))
        let launcher = LeoCountingSFTPLauncher(
            LeoSFTPProcessLauncher(
                executable: URL(fileURLWithPath: fakeSSH),
                arguments: try command.sftpArguments(controlPath: "/tmp/leo-b233-control"),
                fallbackArguments: try command.sftpBootstrapArguments(controlPath: "/tmp/leo-b233-control")
            )
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        let entries = try await access.list(sandbox.path("workspace"))
        let contents = try await access.read(surfaced, maxBytes: 1024)

        #expect(entries.map(\.name) == ["result.txt"])
        #expect(String(data: contents.data, encoding: .utf8) == "done")
        #expect(launcher.launches == 1, "a working subsystem needs one child for the shared session")
        await access.close()
    }

    @Test func rejectedSubsystemFallsBackOnceOnTheSameMuxSocket() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.directory("workspace")
        try sandbox.file("workspace/result.txt", "done")
        let invocations = sandbox.path("invocations")
        let fakeSSH = try sandbox.file("ssh", """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(invocations)'
            for argument in "$@"; do
              if [ "$argument" = "-s" ]; then
                echo 'subsystem request failed on channel 0' >&2
                exit 255
              fi
            done
            exec /usr/libexec/sftp-server -d %d
            """, permissions: 0o755)
        let command = LeoSSHCommand(configuration: .init(name: "work", sshTarget: "evan@work.example:2222", identityFile: "/keys/work"))
        let launcher = LeoCountingSFTPLauncher(
            LeoSFTPProcessLauncher(
                executable: URL(fileURLWithPath: fakeSSH),
                arguments: try command.sftpArguments(controlPath: "/tmp/leo-b233-control"),
                fallbackArguments: try command.sftpBootstrapArguments(controlPath: "/tmp/leo-b233-control")
            )
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        let entries = try await access.list(sandbox.path("workspace"))

        #expect(entries.map(\.name) == ["result.txt"])
        #expect(launcher.launches == 2, "one rejected subsystem child, then one fixed-command child")
        let arguments = try String(contentsOfFile: invocations, encoding: .utf8).split(separator: "\n")
        #expect(arguments.count == 2)
        #expect(arguments[0].contains(" -s "))
        #expect(arguments[1].contains(LeoSSHCommand.sftpServerBootstrapCommand))
        #expect(arguments.allSatisfy { $0.contains("ControlPath=/tmp/leo-b233-control") })
        #expect(arguments.allSatisfy { $0.contains("ProxyCommand=/usr/bin/false") })
        await access.close()
    }

    /// A mux client never sees the rejection line: the ControlMaster logs
    /// `mux request: subsystem` and closes the session, so a real
    /// `ssh -s ... sftp` over the master exits 255 with no stderr at all
    /// (OpenSSH 10.3, verified against a host with no `Subsystem sftp`).
    @Test func aSilentExit255FromTheMuxClientFallsBackOnce() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.directory("workspace")
        try sandbox.file("workspace/result.txt", "done")
        let fakeSSH = try sandbox.file("ssh", """
            #!/bin/sh
            for argument in "$@"; do
              if [ "$argument" = "-s" ]; then
                exit 255
              fi
            done
            exec /usr/libexec/sftp-server -d %d
            """, permissions: 0o755)
        let command = LeoSSHCommand(configuration: .init(name: "work", sshTarget: "evan@work.example"))
        let launcher = LeoCountingSFTPLauncher(
            LeoSFTPProcessLauncher(
                executable: URL(fileURLWithPath: fakeSSH),
                arguments: try command.sftpArguments(controlPath: "/tmp/leo-mux-control"),
                fallbackArguments: try command.sftpBootstrapArguments(controlPath: "/tmp/leo-mux-control")
            )
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        let entries = try await access.list(sandbox.path("workspace"))

        #expect(entries.map(\.name) == ["result.txt"])
        #expect(launcher.launches == 2, "one silently rejected subsystem child, then one fixed-command child")
        await access.close()
    }

    @Test(arguments: [Int32(0), Int32(42)])
    func rejectionLookalikesDoNotRunTheFallback(_ status: Int32) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let fakeSSH = try sandbox.file("ssh", """
            #!/bin/sh
            for argument in "$@"; do
              if [ "$argument" = "-s" ]; then
                echo 'subsystem request failed on channel 0' >&2
                exit \(status)
              fi
            done
            exec /usr/libexec/sftp-server -d %d
            """, permissions: 0o755)
        let launcher = LeoCountingSFTPLauncher(
            LeoSFTPProcessLauncher(
                executable: URL(fileURLWithPath: fakeSSH),
                arguments: ["-s", "host", "sftp"],
                fallbackArguments: ["host", LeoSSHCommand.sftpServerBootstrapCommand]
            )
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)
        let expected = LeoFileAccessError.unavailable(
            reason: "the SFTP service exited before starting (status \(status)): "
                + .untrusted("subsystem request failed on channel 0")
        )

        await #expect(throws: expected) { try await access.stat("/") }
        #expect(launcher.launches == 1)
        await access.close()
    }

    @Test(arguments: [
        "fatal: subsystem request failed during initialization",
        "subsystem request failed on channel 0 during initialization"
    ])
    func exit255NoncanonicalDiagnosticsDoNotRunTheFallback(_ diagnostic: String) async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let fakeSSH = try sandbox.file("ssh", """
            #!/bin/sh
            for argument in "$@"; do
              if [ "$argument" = "-s" ]; then
                echo '\(diagnostic)' >&2
                exit 255
              fi
            done
            exec /usr/libexec/sftp-server -d %d
            """, permissions: 0o755)
        let launcher = LeoCountingSFTPLauncher(
            LeoSFTPProcessLauncher(
                executable: URL(fileURLWithPath: fakeSSH),
                arguments: ["-s", "host", "sftp"],
                fallbackArguments: ["host", LeoSSHCommand.sftpServerBootstrapCommand]
            )
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1)
        await access.close()
    }

    @Test func aCanonicalPrefixTruncatedAtTheCaptureLimitDoesNotRunTheFallback() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let canonical = "subsystem request failed on channel 0"
        let padding = String(repeating: "x", count: 4 * 1024 - canonical.utf8.count - 1)
        let fakeSSH = try sandbox.file("ssh", """
            #!/bin/sh
            for argument in "$@"; do
              if [ "$argument" = "-s" ]; then
                printf '\(padding)\\n\(canonical) during initialization\\n' >&2
                exit 255
              fi
            done
            exec /usr/libexec/sftp-server -d %d
            """, permissions: 0o755)
        let launcher = LeoCountingSFTPLauncher(
            LeoSFTPProcessLauncher(
                executable: URL(fileURLWithPath: fakeSSH),
                arguments: ["-s", "host", "sftp"],
                fallbackArguments: ["host", LeoSSHCommand.sftpServerBootstrapCommand]
            )
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1)
        await access.close()
    }

    @Test func aCanonicalRejectionBeforeInvalidUTF8StderrStillFallsBack() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.directory("workspace")
        try sandbox.file("workspace/result.txt", "done")
        let launcher = try rejectingLauncher(
            in: sandbox,
            stderrPrintf: "subsystem request failed on channel 0\\n\\377\\376 junk\\n"
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        let entries = try await access.list(sandbox.path("workspace"))

        #expect(entries.map(\.name) == ["result.txt"])
        #expect(launcher.launches == 2, "one rejected subsystem child, then one fixed-command child")
        await access.close()
    }

    @Test func aCanonicalRejectionBeforeAUTF8SequenceCutAtTheCaptureLimitStillFallsBack() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        try sandbox.directory("workspace")
        try sandbox.file("workspace/result.txt", "done")
        let canonical = "subsystem request failed on channel 0"
        // 4095 bytes captured, then "é" (0xC3 0xA9) straddles the 4096-byte
        // limit: the kept stderr ends in a lone 0xC3.
        let limit = 4 * 1024
        let filler = String(repeating: "x", count: limit - 1 - canonical.utf8.count - 1)
        #expect(canonical.utf8.count + 1 + filler.utf8.count == limit - 1)
        let launcher = try rejectingLauncher(
            in: sandbox,
            stderrPrintf: "\(canonical)\\n\(filler)\\303\\251yyyy\\n"
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        let entries = try await access.list(sandbox.path("workspace"))

        #expect(entries.map(\.name) == ["result.txt"])
        #expect(launcher.launches == 2, "one rejected subsystem child, then one fixed-command child")
        await access.close()
    }

    @Test func aCanonicalLineCarryingInvalidUTF8DoesNotRunTheFallback() async throws {
        let sandbox = try LeoFileSandbox()
        defer { sandbox.cleanUp() }
        let launcher = try rejectingLauncher(
            in: sandbox,
            stderrPrintf: "subsystem request failed on channel 0\\377\\n"
        )
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1)
        await access.close()
    }

    /// A fake `ssh` whose `-s` (subsystem) attempt writes `stderrPrintf`
    /// (a `printf` format, so `\\377` is a raw byte) and exits 255, while
    /// the fixed-command fallback serves SFTP.
    private func rejectingLauncher(
        in sandbox: LeoFileSandbox,
        stderrPrintf: String
    ) throws -> LeoCountingSFTPLauncher {
        let fakeSSH = try sandbox.file("ssh", """
            #!/bin/sh
            for argument in "$@"; do
              if [ "$argument" = "-s" ]; then
                printf '\(stderrPrintf)' >&2
                exit 255
              fi
            done
            exec /usr/libexec/sftp-server -d %d
            """, permissions: 0o755)
        return LeoCountingSFTPLauncher(
            LeoSFTPProcessLauncher(
                executable: URL(fileURLWithPath: fakeSSH),
                arguments: ["-s", "host", "sftp"],
                fallbackArguments: ["host", LeoSSHCommand.sftpServerBootstrapCommand]
            )
        )
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

    @Test func aServerThatExitsZeroBeforeVersionIsUnavailable() async throws {
        let transport = LeoSFTPTransport(channel: try LeoSFTPTestServer.script("exit 0").launch())
        defer { transport.close() }

        let expected = LeoFileAccessError.unavailable(reason: "the SFTP service exited before starting (status 0)")
        await #expect(throws: expected) { try await transport.handshake() }
        await #expect(throws: expected) { try await transport.send(.stat(path: "/")) }
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

    @Test func aServerFailureAfterVersionIsUnavailable() async throws {
        let script = "head -c 9 >/dev/null; \(LeoSFTPTestServer.versionReply); head -c 1 >/dev/null; echo 'request service failed' >&2; exit 42"
        let transport = LeoSFTPTransport(channel: try LeoSFTPTestServer.script(script).launch())
        defer { transport.close() }
        _ = try await transport.handshake()

        let expected = LeoFileAccessError.unavailable(
            reason: "the SFTP service stopped (status 42): " + .untrusted("request service failed")
        )
        await #expect(throws: expected) { try await transport.send(.stat(path: "/")) }
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
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script("exit 255"))
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1)
        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 2)
    }

    @Test func concurrentOperationsShareOneFailedHandshakeWithoutSerialRetries() async throws {
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script("sleep 0.1; exit 0"))
        let access = LeoFileAccessor.sftp(launcher: launcher)

        let errors = await withTaskGroup(of: LeoFileAccessError?.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        _ = try await access.stat("/")
                        return nil
                    } catch let error as LeoFileAccessError {
                        return error
                    } catch {
                        return nil
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        let expected = LeoFileAccessError.unavailable(reason: "the SFTP service exited before starting (status 0)")
        #expect(errors.count == 12)
        #expect(errors.allSatisfy { $0 == expected })
        #expect(launcher.launches == 1)
        await #expect(throws: expected) { try await access.stat("/") }
        #expect(launcher.launches == 2, "a later explicit operation gets one fresh attempt")
        await access.close()
    }

    @Test func concurrentOperationsJoinOneReplacementAfterVersionThenEOF() async throws {
        let first = LeoSFTPTestServer.script(
            "head -c 9 >/dev/null; \(LeoSFTPTestServer.versionReply); sleep 0.05"
        )
        let launcher = LeoSequenceSFTPLauncher(first: first, later: LeoSFTPTestServer.launcher())
        let access = LeoFileAccessor.sftp(launcher: launcher)
        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1, "VERSION succeeded before the first child closed")

        let sizes = try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<12 {
                group.addTask { try await access.stat("/").size }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(sizes.count == 12)
        #expect(launcher.launches == 2, "one stale handshake, then one shared replacement")
        await access.close()
    }

    @Test func everyVersionThenEOFAttemptIsBoundedPerExplicitOperation() async throws {
        let server = LeoSFTPTestServer.script(
            "head -c 9 >/dev/null; \(LeoSFTPTestServer.versionReply)"
        )
        let launcher = LeoLimitedSFTPLauncher(server, limit: 2)
        let session = LeoSFTPSession(launcher: launcher) { client in
            while !client.transport.isClosed { await Task.yield() }
        }

        await #expect(throws: LeoFileAccessError.disconnected) { try await session.client() }
        #expect(launcher.attempts == 1)
        await #expect(throws: LeoFileAccessError.disconnected) { try await session.client() }
        #expect(launcher.attempts == 2, "the next explicit operation gets one fresh attempt")
        await session.close()
    }

    @Test func publicSessionEndLogOmitsRemoteFailureDetail() {
        let secret = "remote-token-8b4f3f2d"
        let error = LeoFileAccessError.unavailable(reason: "service failed: " + .untrusted(secret))

        let description = LeoSFTPTransport.publicLogDescription(for: error)

        #expect(!description.contains(secret))
        #expect(description == "unavailable")
        #expect(error.localizedDescription.contains(secret), "the user-facing error remains actionable")
    }

    @Test func closeDuringAReplacementStopsOldWaitersLaunchingMoreChildren() async throws {
        let first = LeoSFTPTestServer.script(
            "head -c 9 >/dev/null; \(LeoSFTPTestServer.versionReply); sleep 0.05"
        )
        let launcher = LeoSequenceSFTPLauncher(first: first, later: LeoSFTPTestServer.script("exec sleep 30"))
        let access = LeoFileAccessor.sftp(launcher: launcher)
        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1, "the closed successful handshake remains current")
        let requests = (0..<12).map { _ in Task { try await access.stat("/") } }
        while launcher.launches < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(25))

        await access.close()

        for request in requests {
            await #expect(throws: LeoFileAccessError.closed) { try await request.value }
        }
        #expect(launcher.launches == 2)
    }

    @Test func closeWinsOverStartupFailureClassification() async throws {
        let script = "exec 1>&-; echo 'late service failure' >&2; sleep 0.2; exit 42"
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script(script))
        let access = LeoFileAccessor.sftp(launcher: launcher)
        let request = Task { try await access.stat("/") }
        while launcher.launches == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(25))

        await access.close()

        await #expect(throws: LeoFileAccessError.closed) { try await request.value }
        #expect(launcher.launches == 1)
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
