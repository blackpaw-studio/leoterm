import Darwin
import Foundation
import Testing

@testable import Ghostty

/// What sits at a ControlMaster path decides whether it may be removed:
/// only a socket nobody is listening on. Everything else -- a live master
/// (possibly another app instance's), a regular file, a symlink, a
/// directory -- is left alone.
@Suite(.serialized)
struct LeoControlSocketTests {
    @Test func aMissingPathIsAbsent() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }

        #expect(LeoControlSocket.inspect(directory.path("cm")) == .absent)
    }

    @Test func aListeningSocketIsLive() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let descriptor = try LeoTestUnixSocket.bind(directory.path("cm"), listening: true)
        defer { close(descriptor) }

        #expect(LeoControlSocket.inspect(directory.path("cm")) == .live)
    }

    @Test func aSocketNobodyListensOnIsStale() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        try LeoTestUnixSocket.leaveStale(directory.path("cm"))

        #expect(LeoControlSocket.inspect(directory.path("cm")) == .stale)
    }

    @Test func regularFilesSymlinksAndDirectoriesAreNotSockets() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        #expect(FileManager.default.createFile(atPath: directory.path("file"), contents: Data("x".utf8)))
        try LeoTestUnixSocket.leaveStale(directory.path("target"))
        try FileManager.default.createSymbolicLink(atPath: directory.path("link"), withDestinationPath: directory.path("target"))
        try FileManager.default.createDirectory(atPath: directory.path("dir"), withIntermediateDirectories: false)

        #expect(LeoControlSocket.inspect(directory.path("file")) == .notASocket)
        #expect(LeoControlSocket.inspect(directory.path("link")) == .notASocket, "a symlink is never followed, even to a socket")
        #expect(LeoControlSocket.inspect(directory.path("dir")) == .notASocket)
    }

    @Test func removingAStaleSocketUnlinksIt() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        try LeoTestUnixSocket.leaveStale(directory.path("cm"))

        #expect(LeoControlSocket.removeIfStale(directory.path("cm")) == .stale)
        #expect(LeoControlSocket.inspect(directory.path("cm")) == .absent)
    }

    /// The debug bundle must never kill the production app's live master.
    @Test func aLiveSocketIsNeverRemoved() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        let descriptor = try LeoTestUnixSocket.bind(directory.path("cm"), listening: true)
        defer { close(descriptor) }

        #expect(LeoControlSocket.removeIfStale(directory.path("cm")) == .live)
        #expect(LeoControlSocket.inspect(directory.path("cm")) == .live)
    }

    @Test func nonSocketsAreNeverRemoved() throws {
        let directory = try LeoTestSocketDirectory()
        defer { directory.remove() }
        #expect(FileManager.default.createFile(atPath: directory.path("file"), contents: Data("keep".utf8)))
        try LeoTestUnixSocket.leaveStale(directory.path("target"))
        try FileManager.default.createSymbolicLink(atPath: directory.path("link"), withDestinationPath: directory.path("target"))
        try FileManager.default.createDirectory(atPath: directory.path("dir"), withIntermediateDirectories: false)

        for name in ["file", "link", "dir"] {
            #expect(LeoControlSocket.removeIfStale(directory.path(name)) == .notASocket, "\(name)")
        }

        #expect(try String(contentsOfFile: directory.path("file"), encoding: .utf8) == "keep")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: directory.path("link")) == directory.path("target"))
        #expect(LeoControlSocket.inspect(directory.path("target")) == .stale, "a symlink's target is never touched")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path("dir"), isDirectory: &isDirectory) && isDirectory.boolValue)
    }
}

/// A short, private directory under `/tmp` (AF_UNIX paths cap at 104 bytes).
struct LeoTestSocketDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: "/tmp/leo-cs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func path(_ name: String) -> String { url.appendingPathComponent(name).path }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

enum LeoTestUnixSocket {
    /// A bound AF_UNIX socket at `path`; the caller closes the descriptor.
    static func bind(_ path: String, listening: Bool) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, !listening || listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        return descriptor
    }

    /// What a crashed master leaves behind: a socket file nobody listens on.
    static func leaveStale(_ path: String) throws {
        close(try bind(path, listening: false))
    }
}
