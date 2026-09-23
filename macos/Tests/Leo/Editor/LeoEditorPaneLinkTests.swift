import Foundation
import Testing

@testable import Ghostty

/// Opening a surfaced link for an agent: relative paths resolve against
/// its workspace, `~` against its host's home, and the file opens on the
/// agent's host.
@MainActor
struct LeoEditorPaneLinkTests {
    nonisolated static let kinds: [LeoFileBackendKind] = [.local, .sftp]

    private func makePane(_ kind: LeoFileBackendKind, home: String? = nil, hosts: LeoHostLog? = nil) -> LeoEditorPaneModel {
        LeoEditorPaneModel(makeAccess: { host in
            hosts?.hosts.append(host)
            let access = kind.makeAccess()
            return home.map { LeoFixedHomeAccess(access, home: $0) } ?? access
        })
    }

    @Test(arguments: kinds)
    func aRelativeLinkOpensInTheAgentsWorkspaceAtItsLine(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.directory("agent/src")
            try sandbox.file("agent/src/main.swift", "a\nb\nc\n")
            let pane = makePane(kind)
            let agent = LeoEditorAgentContext(host: .local, name: "app", workspace: sandbox.path("agent"))

            #expect(try await pane.open(link: "src/main.swift:2", for: agent) == .opened)

            #expect(pane.document?.fileID == LeoEditorFileID(host: .local, path: sandbox.path("agent/src/main.swift")))
            #expect(pane.reveal?.line == 2)
            await pane.close()
        }
    }

    @Test(arguments: kinds)
    func aTildeLinkOpensInTheHostsHome(_ kind: LeoFileBackendKind) async throws {
        try await withLeoFileSandbox(kind) { sandbox, _ in
            try sandbox.file("notes.md", "# Notes")
            let pane = makePane(kind, home: sandbox.root)
            let agent = LeoEditorAgentContext(host: .local, name: "app", workspace: nil)

            try await pane.open(link: "~/notes.md", for: agent)

            #expect(pane.document?.text == "# Notes")
            await pane.close()
        }
    }

    @Test func theFileOpensOnTheAgentsHost() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let path = try sandbox.file("a.txt", "a")
            let hosts = LeoHostLog()
            let pane = makePane(.local, hosts: hosts)
            let agent = LeoEditorAgentContext(host: .remote("devbox"), name: "app", workspace: nil)

            try await pane.open(link: "file://devbox\(path)", for: agent)

            #expect(pane.document?.fileID == LeoEditorFileID(host: .remote("devbox"), path: path))
            #expect(hosts.hosts == [.remote("devbox")])
            await pane.close()
        }
    }

    @Test func aRelativeLinkWithoutAWorkspaceFailsWithoutTouchingTheHost() async throws {
        let hosts = LeoHostLog()
        let pane = makePane(.local, hosts: hosts)
        let agent = LeoEditorAgentContext(host: .local, name: "app", workspace: nil)

        await #expect(throws: LeoEditorLinkError.noWorkspace) { try await pane.open(link: "src/a.swift", for: agent) }
        #expect(hosts.hosts.isEmpty)
        #expect(pane.document == nil)
    }
}

@MainActor final class LeoHostLog {
    var hosts: [LeoHostID] = []
}

/// `base` with a fixed home directory (tests can't write to the real one).
final class LeoFixedHomeAccess: LeoFileAccess, @unchecked Sendable {
    private let base: any LeoFileAccess
    private let home: String

    init(_ base: any LeoFileAccess, home: String) {
        self.base = base
        self.home = home
    }

    func homeDirectory() async throws -> String { home }
    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }
    func close() async { await base.close() }
}
