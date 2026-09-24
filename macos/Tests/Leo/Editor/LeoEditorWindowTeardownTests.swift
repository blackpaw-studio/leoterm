import AppKit
import Foundation
import Testing

@testable import Ghostty

/// A window's editor holds file access (for a remote host, an `sftp`
/// process): closing the window releases it.
@MainActor
struct LeoEditorWindowTeardownTests {
    @Test(.timeLimit(.minutes(1)))
    func closingTheWindowReleasesTheOpenFilesAccess() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let access = LeoCloseSpyAccess(LeoFileAccessor.local())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            let defaults = LeoInMemoryDefaults()
            let session = LeoWindowSession(window: window, defaults: defaults, makeFileAccess: { _ in access })
            try await session.editor.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            #expect(!access.isClosed)

            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

            #expect(await access.waitUntilClosed(for: .seconds(5)))
            #expect(session.editor.document == nil)
        }
    }
}

/// `base`, recording `close()`.
final class LeoCloseSpyAccess: LeoFileAccess, @unchecked Sendable {
    private let base: any LeoFileAccess
    private let lock = NSLock()
    private var closed = false

    init(_ base: any LeoFileAccess) {
        self.base = base
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Polls: `close()` arrives from a task the window's teardown starts.
    func waitUntilClosed(for timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !isClosed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isClosed
    }

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }

    func close() async {
        await base.close()
        lock.withLock { closed = true }
    }
}
