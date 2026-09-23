import Darwin
import Foundation
import Testing

@testable import Ghostty

/// The forwarded daemon socket used to live in `~/.leo/state/leoterm/`,
/// where a long home directory pushed it past the AF_UNIX path limit and
/// broke the whole tunnel. It now sits beside the ControlMaster sockets in
/// `LeoControlSocketDirectory`, under the same checks.
@Suite(.serialized)
struct LeoTunnelSocketPathTests {
    private let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")

    @MainActor @Test func aLongHomeDirectoryStillYieldsAUsableTunnelSocketPath() throws {
        let home = "/Users/" + String(repeating: "h", count: 80)
        let defaults = try #require(UserDefaults(suiteName: "LeoTunnelSocketPathTests.\(UUID().uuidString)"))
        let selection = LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            legacySocketDirectory: URL(fileURLWithPath: home + "/.leo/state/leoterm", isDirectory: true)
        )

        let path = selection.tunnelSocketPath(for: configuration)

        #expect(!path.hasPrefix(home))
        #expect(throws: Never.self) {
            try LeoSSHCommand(configuration: configuration).tunnelArguments(
                localSocketPath: path, remoteSocketPath: "/remote/leo.sock", controlPath: nil
            )
        }
    }

    /// Fixed length whatever the host's name, so the path fits for every
    /// user or for none; scoped to the app bundle (the debug and release
    /// apps share the directory) and keyed by id, so reconnects find it.
    @Test func theTunnelSocketNameIsFixedLengthAndScopedToTheAppAndHost() throws {
        let zero = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        let host = LeoHostConfiguration(id: zero, name: "a b", sshTarget: "build")
        let long = LeoHostConfiguration(name: String(repeating: "x", count: 200), sshTarget: "build")

        #expect(host.tunnelSocketFileName(instance: "aaaaaaaa") == "lt-aaaaaaaa-000000000000.sock")
        #expect(long.tunnelSocketFileName(instance: "aaaaaaaa").utf8.count == 29)
        #expect(host.tunnelSocketFileName(instance: "aaaaaaaa") != host.tunnelSocketFileName(instance: "bbbbbbbb"))
        #expect(host.tunnelSocketFileName(instance: "aaaaaaaa") != host.controlSocketFileName(instance: "aaaaaaaa"))
    }

    @MainActor @Test func theTunnelListensInTheControlSocketDirectory() async throws {
        let (legacy, control) = Self.makeDirectories()
        defer { Self.remove(legacy, control) }
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], localSocketDirectory: legacy, controlSocketDirectory: control
        )
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))

        let expected = control.appendingPathComponent(
            configuration.tunnelSocketFileName(instance: LeoHostSelection.defaultControlSocketInstance)
        ).path
        await LeoHostSelectionTestSupport.awaitConnected(selection, expected)
        #expect(Self.mode(control) == 0o700)
        selection.shutdown()
    }

    /// Another user's socket at the path could be a fake daemon: never
    /// removed, never used.
    @MainActor @Test func aForeignSocketAtTheTunnelPathIsRefused() async throws {
        let (legacy, control) = Self.makeDirectories()
        defer { Self.remove(legacy, control) }
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], localSocketDirectory: legacy, controlSocketDirectory: control, controlSocketOwner: geteuid() + 1
        )
        let path = selection.tunnelSocketPath(for: configuration)
        let listener = try LeoTestUnixSocket.bind(path, listening: true)
        defer { close(listener) }
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))

        await LeoHostSelectionTestSupport.awaitFailed(selection)
        #expect(Self.failureMessage(selection).contains("another user"))
        #expect(LeoControlSocket.inspect(path) == .live)
        selection.shutdown()
    }

    @MainActor @Test func aFileAtTheTunnelPathIsLeftAlone() async throws {
        let (legacy, control) = Self.makeDirectories()
        defer { Self.remove(legacy, control) }
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], localSocketDirectory: legacy, controlSocketDirectory: control
        )
        let path = selection.tunnelSocketPath(for: configuration)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))

        await LeoHostSelectionTestSupport.awaitFailed(selection)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep")
        selection.shutdown()
    }

    /// A live socket at the path is another copy of the app forwarding the
    /// same host: never unlinked and rebound, the user sees why instead.
    @MainActor @Test func aLiveSiblingAtTheTunnelPathSurvivesAndTheConnectionFails() async throws {
        let (legacy, control) = Self.makeDirectories()
        defer { Self.remove(legacy, control) }
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], localSocketDirectory: legacy, controlSocketDirectory: control
        )
        let path = selection.tunnelSocketPath(for: configuration)
        let listener = try LeoTestUnixSocket.bind(path, listening: true)
        defer { close(listener) }
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))

        await LeoHostSelectionTestSupport.awaitFailed(selection)
        #expect(Self.failureMessage(selection).contains("already in use"))
        #expect(LeoControlSocket.inspect(path) == .live)
        selection.shutdown()
    }

    /// A parent others can rewrite could have the checked directory swapped.
    @MainActor @Test func anUnsafeSocketDirectoryIsRefused() async throws {
        let (legacy, parent) = Self.makeDirectories()
        defer { Self.remove(legacy, parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        #expect(chmod(parent.path, 0o777) == 0)
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration], localSocketDirectory: legacy,
            controlSocketDirectory: parent.appendingPathComponent("leo", isDirectory: true)
        )
        await selection.start(flavor: .socketEvents)

        selection.select(.remote("work"))

        await LeoHostSelectionTestSupport.awaitFailed(selection)
        #expect(Self.failureMessage(selection).contains("not private"))
        selection.shutdown()
    }

    /// Upgrading leaves the old location's socket behind; a dead one is
    /// removed, anything else there is never touched.
    @MainActor @Test func onlyAStaleSocketAtTheOldLocationIsRemoved() async throws {
        let (legacy, control) = Self.makeDirectories()
        defer { Self.remove(legacy, control) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let other = LeoHostConfiguration(name: "other", sshTarget: "evan@other", remoteSocketPath: "/remote/leo.sock")
        let third = LeoHostConfiguration(name: "third", sshTarget: "evan@third", remoteSocketPath: "/remote/leo.sock")
        let stale = legacy.appendingPathComponent(configuration.legacySocketFileName).path
        let live = legacy.appendingPathComponent(other.legacySocketFileName).path
        let file = legacy.appendingPathComponent(third.legacySocketFileName).path
        try LeoTestUnixSocket.leaveStale(stale)
        let listener = try LeoTestUnixSocket.bind(live, listening: true)
        defer { close(listener) }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: file))
        let selection = LeoHostSelectionTestSupport.makeSelection(
            hosts: [configuration, other, third], localSocketDirectory: legacy, controlSocketDirectory: control
        )
        await selection.start(flavor: .socketEvents)

        for host in [other, third, configuration] {
            selection.select(.remote(host.name))
            await LeoHostSelectionTestSupport.awaitConnected(selection, selection.tunnelSocketPath(for: host))
        }

        #expect(LeoControlSocket.inspect(stale) == .absent)
        #expect(LeoControlSocket.inspect(live) == .live)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "keep")
        selection.shutdown()
    }

    /// The OS can purge the directory under a running tunnel: the error
    /// says to reconnect rather than naming a path.
    @Test func aVanishedTunnelSocketSaysToReconnect() async throws {
        let transport = LeoTunnelSocketTransport(base: LeoMissingSocketTransport())

        await #expect(throws: LeoDaemonError.hostUnavailable(LeoTunnelSocketTransport.vanishedMessage)) {
            _ = try await transport.send(LeoHTTPRequest(method: "GET", path: "/health"), socketPath: "/gone", timeout: 1)
        }
        await #expect(throws: LeoDaemonError.hostUnavailable(LeoTunnelSocketTransport.vanishedMessage)) {
            for try await _ in transport.stream(path: "/events", socketPath: "/gone", idleTimeout: 1) {}
        }
        #expect(LeoTunnelSocketTransport.vanishedMessage.contains("Reconnect"))
    }

    private static func makeDirectories() -> (legacy: URL, control: URL) {
        (LeoHostSelectionTestSupport.makeIsolatedSocketDirectory(), LeoHostSelectionTestSupport.makeIsolatedSocketDirectory())
    }

    private static func remove(_ urls: URL...) {
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    @MainActor private static func failureMessage(_ selection: LeoHostSelection) -> String {
        guard case .failed(let message, _) = selection.state else { return "" }
        return message
    }

    private static func mode(_ url: URL) -> mode_t {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return info.st_mode & 0o777
    }
}

private struct LeoMissingSocketTransport: LeoSocketActivityTransport {
    func send(_: LeoHTTPRequest, socketPath: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        throw LeoDaemonError.socketMissing(path: socketPath)
    }

    func stream(path _: String, socketPath: String, idleTimeout _: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish(throwing: LeoDaemonError.socketMissing(path: socketPath)) }
    }
}
