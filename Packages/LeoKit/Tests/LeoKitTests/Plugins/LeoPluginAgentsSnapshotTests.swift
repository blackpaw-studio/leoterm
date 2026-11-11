import Foundation
import Testing

@testable import LeoKit

private func engine(read: Bool) -> LeoPluginPermissionEngine {
    LeoPluginPermissionEngine(permissions: LeoPluginPermissions(agents: read ? [.read] : []))
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
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("/secret"))
        #expect(!json.contains("/Users"))
        #expect(!json.lowercased().contains("path"))
        #expect(!json.contains("workspace"))
        let keys = Set(Mirror(reflecting: snapshot[0]).children.compactMap(\.label))
        #expect(keys == ["name", "machine", "status", "repo", "branch", "hasWorktree"])
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
}
