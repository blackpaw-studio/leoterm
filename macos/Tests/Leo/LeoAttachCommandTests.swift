import Foundation
import Testing

@testable import Ghostty

struct LeoAttachCommandTests {
    @Test func buildsLocalCommand() throws {
        let command = try LeoAttachCommand.build(executable: "/opt/leo", identity: .init(host: .local, name: "worker"))
        #expect(command == "env -u TMUX -u TMUX_PANE '/opt/leo' agent attach -- 'worker'")
    }

    @Test func quotesHostileName() throws {
        let identity = LeoAgentIdentity(host: .local, name: "it's $(bad) agent")
        #expect(try LeoAttachCommand.build(executable: "/leo path", identity: identity) == "env -u TMUX -u TMUX_PANE '/leo path' agent attach -- 'it'\\''s $(bad) agent'")
    }

    @Test func includesRemoteHost() throws {
        let identity = LeoAgentIdentity(host: .remote("build host"), name: "worker")
        #expect(try LeoAttachCommand.build(executable: "/leo", identity: identity) == "env -u TMUX -u TMUX_PANE '/leo' agent attach --host 'build host' -- 'worker'")
    }

    @Test(arguments: ["--help", "-x", "--cc"])
    func namesStartingWithFlagsFollowDelimiter(_ name: String) throws {
        let command = try LeoAttachCommand.build(executable: "/leo", identity: .init(host: .local, name: name))
        #expect(command == "env -u TMUX -u TMUX_PANE '/leo' agent attach -- '\(name)'")
    }

    @Test(arguments: ["bad\0name", "bad\nname", "bad\rname"])
    func rejectsInvalidNames(_ name: String) {
        #expect(throws: LeoAttachCommandError.invalidAgentName) {
            try LeoAttachCommand.build(executable: "/leo", identity: .init(host: .local, name: name))
        }
    }

    @Test func selectsExistingWorkspaceThenRepoThenHome() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let workspace = root.appending(path: "workspace")
        let repo = root.appending(path: "repo")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(LeoAttachCommand.workingDirectory(identity: .init(host: .local, name: "a", workspace: workspace.path, repo: repo.path)) == workspace.path)
        #expect(LeoAttachCommand.workingDirectory(identity: .init(host: .local, name: "a", workspace: root.appending(path: "missing").path, repo: repo.path)) == repo.path)
        #expect(LeoAttachCommand.workingDirectory(identity: .init(host: .local, name: "a", workspace: nil, repo: root.appending(path: "missing").path)) == nil)
        #expect(LeoAttachCommand.workingDirectory(identity: .init(host: .remote("host"), name: "a", workspace: workspace.path, repo: repo.path)) == nil)
    }
}
