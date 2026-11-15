import Foundation
import Testing

@testable import LeoKit

private func engine(read: Bool) -> LeoPluginPermissionEngine {
    LeoPluginPermissionEngine(permissions: LeoPluginPermissions(agents: read ? [.read] : []))
}

private func engine(_ verbs: [LeoPluginAgentVerb]) -> LeoPluginPermissionEngine {
    LeoPluginPermissionEngine(permissions: LeoPluginPermissions(agents: verbs))
}

struct LeoPluginAgentsSnapshotTests {
    private let agents: [(LeoHostID, LeoAgent)] = [
        (.local, LeoAgent(name: "alfred", repo: "blackpaw-studio/leoterm", workspace: "/Users/evan/.leo/agents/alfred", branch: "agent/alfred", canonicalPath: "/secret/worktrees/alfred", status: .running)),
        (.remote("dionysus"), LeoAgent(name: "scratch", status: .stopped)),
        (.local, LeoAgent(name: "odd", status: .unknown("migrating"))),
        (.local, LeoAgent(name: "nostatus")),
    ]

    @Test func buildsTheDocumentedFieldsPerAgent() throws {
        let snapshot = try LeoPluginAgentsSnapshot.list(agents: agents, engine: engine(read: true))
        #expect(snapshot.count == 4)
        #expect(snapshot[0] == LeoPluginAgentSnapshotEntry(
            name: "alfred", machine: "localhost", status: "running", repo: "blackpaw-studio/leoterm",
            branch: "agent/alfred", hasWorktree: true))
        #expect(snapshot[1] == LeoPluginAgentSnapshotEntry(
            name: "scratch", machine: "dionysus", status: "stopped", repo: nil, branch: nil, hasWorktree: false))
        #expect(snapshot[2].status == "migrating")
        #expect(snapshot[3].status == "unknown")
    }

    @Test func exposesNoPathOfAnyKind() throws {
        let snapshot = try LeoPluginAgentsSnapshot.list(agents: agents, engine: engine(read: true))
        let json = String(bytes: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        #expect(!json.contains("/secret"))
        #expect(!json.contains("/Users"))
        #expect(!json.lowercased().contains("path"))
        #expect(!json.contains("workspace"))
        #expect(snapshot.allSatisfy { $0.workspace == nil && $0.model == nil })
        // The reply (what the plugin actually receives) has exactly the base keys.
        let reply = try LeoPluginAgentsSnapshot.value(agents: agents, engine: engine(read: true))
        guard case .array(let entries) = reply else { Issue.record("expected an array"); return }
        for case .object(let fields) in entries {
            #expect(Set(fields.keys) == ["name", "machine", "status", "repo", "branch", "hasWorktree"])
        }
    }

    @Test func requiresTheAgentsReadPermission() {
        #expect(throws: LeoPluginAgentsSnapshotError.self) {
            _ = try LeoPluginAgentsSnapshot.list(agents: agents, engine: engine(read: false))
        }
    }

    @Test func sendAloneDoesNotGrantRead() {
        let sendOnly = LeoPluginPermissionEngine(permissions: LeoPluginPermissions(agents: [.send]))
        #expect(throws: LeoPluginAgentsSnapshotError.self) {
            _ = try LeoPluginAgentsSnapshot.list(agents: agents, engine: sendOnly)
        }
    }

    @Test func producesAJSONValueForTheReply() throws {
        let value = try LeoPluginAgentsSnapshot.value(agents: [agents[1]], engine: engine(read: true))
        #expect(value == .array([
            .object([
                "name": .string("scratch"), "machine": .string("dionysus"), "status": .string("stopped"),
                "repo": .null, "branch": .null, "hasWorktree": .bool(false),
            ])
        ]))
    }

    // MARK: usage-gated fields (model, workspace)

    private let home = "/Users/evan"

    private func entries(
        _ list: [(LeoHostID, LeoAgent)], verbs: [LeoPluginAgentVerb], observed: String? = nil
    ) throws -> [LeoPluginAgentSnapshotEntry] {
        try LeoPluginAgentsSnapshot.list(
            agents: list, engine: engine(verbs), usage: { _ in
                LeoPluginUsageReading(configuredModel: nil, usage: observed.map { LeoAgentUsage(session: LeoUsageTotals(tokens: 1, costUSD: 1), model: $0) }, harnessReportsUsage: true)
            }, homeDirectory: home)
    }

    @Test func modelAndWorkspaceAreOmittedWithoutTheUsagePermission() throws {
        let list = [(LeoHostID.local, LeoAgent(name: "a", workspace: "/Users/evan/.leo/agents/a", model: "configured"))]
        let readOnly = try entries(list, verbs: [.read], observed: "observed")
        #expect(readOnly[0].workspace == nil)
        #expect(readOnly[0].model == nil)
        let reply = try LeoPluginAgentsSnapshot.value(agents: list, engine: engine([.read, .send, .spawn]), usage: { _ in nil }, homeDirectory: home)
        guard case .array(let values) = reply, case .object(let fields)? = values.first else { Issue.record("no entry"); return }
        #expect(!fields.keys.contains("workspace"))
        #expect(!fields.keys.contains("model"))
    }

    @Test func usageAloneDoesNotGrantTheListItself() {
        #expect(throws: LeoPluginAgentsSnapshotError.self) { _ = try entries([agents[0]], verbs: [.usage]) }
    }

    @Test func withUsageTheEntryCarriesTheObservedModelElseTheConfiguredOne() throws {
        let list = [(LeoHostID.local, LeoAgent(name: "a", model: "configured"))]
        #expect(try entries(list, verbs: [.read, .usage], observed: "observed")[0].model == "observed")
        #expect(try entries(list, verbs: [.read, .usage])[0].model == "configured")
        #expect(try entries([(.local, LeoAgent(name: "a"))], verbs: [.read, .usage])[0].model == nil)
    }

    @Test func aLocalWorkspaceIsHomeRelativeAndOneOutsideHomeStaysAbsolute() throws {
        func workspace(_ path: String?, host: LeoHostID = .local) throws -> String? {
            try entries([(host, LeoAgent(name: "a", workspace: path))], verbs: [.read, .usage])[0].workspace
        }
        #expect(try workspace("/Users/evan/.leo/agents/leoterm") == "~/.leo/agents/leoterm")
        #expect(try workspace("/Users/evan") == "~")
        #expect(try workspace("/Users/evan/") == "~")
        #expect(try workspace("/srv/work/leoterm") == "/srv/work/leoterm")
        #expect(try workspace("/Users/evanescent/x") == "/Users/evanescent/x")
        #expect(try workspace(nil) == nil)
        #expect(try workspace("") == nil)
    }

    @Test func aDotDotEscapeFromHomeIsNotShortened() throws {
        let list = [(LeoHostID.local, LeoAgent(name: "a", workspace: "/Users/evan/../root/secret"))]
        #expect(try entries(list, verbs: [.read, .usage])[0].workspace == "/Users/root/secret")
    }

    @Test func aRemoteWorkspaceIsNeverShortenedAgainstTheLocalHome() throws {
        let list = [(LeoHostID.remote("dionysus"), LeoAgent(name: "a", workspace: "/Users/evan/work"))]
        #expect(try entries(list, verbs: [.read, .usage])[0].workspace == "/Users/evan/work")
    }

    @Test(arguments: ["relative/path", "/tmp/with\nnewline", "/tmp/nul\u{0}", "/tmp/\u{202E}rtl"])
    func aMalformedWorkspaceIsDroppedRatherThanSent(_ path: String) throws {
        let list = [(LeoHostID.local, LeoAgent(name: "a", workspace: path))]
        #expect(try entries(list, verbs: [.read, .usage])[0].workspace == nil)
    }

    @Test func anOverlongWorkspaceIsDropped() throws {
        let list = [(LeoHostID.local, LeoAgent(name: "a", workspace: "/" + String(repeating: "a", count: 5_000)))]
        #expect(try entries(list, verbs: [.read, .usage])[0].workspace == nil)
    }

    @Test func theReplyCarriesModelAndWorkspaceOnlyWhenPresent() throws {
        let list = [
            (LeoHostID.local, LeoAgent(name: "a", workspace: "/Users/evan/x", model: "m")),
            (LeoHostID.local, LeoAgent(name: "b")),
        ]
        let reply = try LeoPluginAgentsSnapshot.value(agents: list, engine: engine([.read, .usage]), usage: { _ in nil }, homeDirectory: home)
        guard case .array(let values) = reply, case .object(let a) = values[0], case .object(let b) = values[1] else {
            Issue.record("bad reply")
            return
        }
        #expect(a["workspace"] == .string("~/x"))
        #expect(a["model"] == .string("m"))
        #expect(!b.keys.contains("workspace"))
        #expect(!b.keys.contains("model"))
    }
}
