import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

struct LeoDrawerShellLaunchTests {
    private let shell = LeoDaemonFeatures(["agent_shell"])
    private func local(workspace: String? = "/w/alfred", repo: String? = "/r/alfred") -> LeoAgentIdentity {
        LeoAgentIdentity(host: .local, name: "alfred", workspace: workspace, repo: repo)
    }
    private let remote = LeoAgentIdentity(host: .remote("Build"), name: "alfred", workspace: "/w/alfred", repo: nil)

    private func choose(
        _ identity: LeoAgentIdentity, features: LeoDaemonFeatures = .none, isConnected: Bool = true,
        directories: Set<String> = ["/w/alfred", "/r/alfred"], command: @escaping (LeoAgentIdentity) throws -> String = { _ in "ssh x" }
    ) -> LeoDrawerShellLaunch {
        LeoDrawerShellLauncher.choose(
            identity: identity, features: features, isConnected: isConnected, home: "/Users/evan",
            isDirectory: { directories.contains($0) }, remoteCommand: command)
    }

    @Test func aLocalAgentStartsInItsWorkspace() {
        #expect(choose(local()) == .local(workingDirectory: "/w/alfred"))
    }

    @Test func aGoneWorkspaceFallsBackToTheRepoThenHome() {
        #expect(choose(local(), directories: ["/r/alfred"]) == .local(workingDirectory: "/r/alfred"))
        #expect(choose(local(), directories: []) == .local(workingDirectory: "/Users/evan"))
        #expect(choose(local(workspace: nil, repo: nil)) == .local(workingDirectory: "/Users/evan"))
    }

    @Test func aLocalAgentNeverNeedsTheFeatureOrAConnection() {
        #expect(choose(local(), features: .none, isConnected: false) == .local(workingDirectory: "/w/alfred"))
    }

    @Test func aRemoteAgentWithAgentShellRunsTheBuiltCommand() {
        var asked: LeoAgentIdentity?
        let launch = choose(remote, features: shell) { asked = $0; return "env ssh -t build 'leo agent shell -- alfred'" }
        #expect(launch == .remote(command: "env ssh -t build 'leo agent shell -- alfred'"))
        #expect(asked == remote)
    }

    @Test func aRemoteAgentWithoutAgentShellSaysTheMachineNeedsANewerLeo() {
        var built = false
        let launch = choose(remote, features: LeoDaemonFeatures(["agent_move"])) { _ in built = true; return "x" }
        #expect(launch == .unavailable("Terminals for agents on Build need a newer Leo on that machine."))
        #expect(!built)
    }

    @Test func aDisconnectedRemoteHostIsNotConnectedRatherThanOld() {
        let launch = choose(remote, features: .none, isConnected: false)
        #expect(launch == .unavailable("Build isn't connected."))
    }

    @Test func aCommandThatCannotBeBuiltIsUnavailableNotACrash() {
        let launch = choose(remote, features: shell) { _ in throw LeoAttachCommandError.invalidAgentName }
        guard case .unavailable(let message) = launch else { Issue.record("expected unavailable, got \(launch)"); return }
        #expect(message.hasPrefix("Couldn't start a terminal on Build"))
    }
}
