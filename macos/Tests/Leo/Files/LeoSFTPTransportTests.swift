import Foundation
import Testing

@testable import Ghostty

/// The SFTP session layer against the real macOS `sftp-server` and against
/// scripted fake servers that misbehave on cue.
struct LeoSFTPTransportTests {
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

    @Test func aLaunchFailureIsDisconnected() async throws {
        let launcher = LeoSFTPProcessLauncher(executable: URL(fileURLWithPath: "/nonexistent/sftp-server"), arguments: [])
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
    }

    @Test func eachOperationAfterADisconnectMakesExactlyOneFreshAttempt() async throws {
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.script("exit 0"))
        let access = LeoFileAccessor.sftp(launcher: launcher)

        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 1)
        await #expect(throws: LeoFileAccessError.disconnected) { try await access.stat("/") }
        #expect(launcher.launches == 2)
    }

    @Test func oneSessionServesManyOperationsAndReopensAfterClose() async throws {
        let launcher = LeoCountingSFTPLauncher(LeoSFTPTestServer.launcher())
        let access = LeoFileAccessor.sftp(launcher: launcher)

        _ = try await access.stat("/")
        _ = try await access.list("/")
        #expect(launcher.launches == 1)

        await access.close()
        _ = try await access.stat("/")
        #expect(launcher.launches == 2)
        await access.close()
    }

    @Test func unsupportedServerVersionsAreRefused() async throws {
        // VERSION 2.
        let script = "head -c 9 >/dev/null; printf '\\000\\000\\000\\005\\002\\000\\000\\000\\002'; exec sleep 5"
        let access = LeoFileAccessor.sftp(launcher: LeoSFTPTestServer.script(script))

        await #expect(throws: LeoFileAccessError.protocolError("server speaks SFTP v2, not v3")) { try await access.stat("/") }
        await access.close()
    }
}
