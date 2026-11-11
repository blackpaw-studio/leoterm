import Foundation
import Testing

import LeoKit
@testable import Ghostty

/// The thin app-side adapters under the plugin manager. The logic they feed
/// is tested in LeoKit; these check what only the app can: the real file
/// events, and which row fields reach a plugin.
struct LeoPluginAppAdaptersTests {
    private static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leo-plugin-adapters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test @MainActor func agentSnapshotCarriesRepoAndBranchButNotTheWorkspacePath() {
        let row = LeoAgentRow(
            host: .remote("hestia"), name: "fix-login", template: "coder", status: .running, activity: .idle, actionDetail: nil,
            workspace: "/Users/evan/secret/worktree", repo: "blackpaw/leo", branch: "fix/login")

        let (host, agent) = LeoPluginAppSources.agent(for: row)

        #expect(host == .remote("hestia"))
        #expect(agent.name == "fix-login")
        #expect(agent.repo == "blackpaw/leo")
        #expect(agent.branch == "fix/login")
        #expect(!String(describing: agent).contains("/Users/evan/secret"))
    }

    @Test func fileEventsReportAWriteToAWatchedFile() async throws {
        let directory = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("main.js")
        try Data("a".utf8).write(to: file)
        let fired = AsyncStream<Void>.makeStream()

        let handle = LeoPluginDispatchFileEvents().watch(file) { fired.continuation.yield() }
        defer { handle?.cancel() }
        try #require(handle != nil)
        let handle2 = try FileHandle(forWritingTo: file)
        try handle2.write(contentsOf: Data("b".utf8))
        try handle2.close()

        var iterator = fired.stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func fileEventsRefuseAMissingPath() throws {
        let directory = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let handle = LeoPluginDispatchFileEvents().watch(directory.appendingPathComponent("nope")) {}

        #expect(handle == nil)
    }

    @Test func hostFactoryMakesAFreshConnectionEachTime() {
        let factory = LeoPluginProcessHostFactory(launcher: LeoPluginPosixLauncher(helperURL: URL(fileURLWithPath: "/nonexistent")))

        let first = factory.makeHost()
        let second = factory.makeHost()

        #expect(first as AnyObject !== second as AnyObject)
    }
}
