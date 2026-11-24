import Foundation
import Testing

@testable import LeoKit

private let usageID = "studio.blackpaw.usage"
private let both = LeoPluginPermissions(network: ["api.anthropic.com", "chatgpt.com"], credentials: [.claudeCode, .codex])

private func usageManifest(_ permissions: LeoPluginPermissions = both) -> LeoPluginManifest {
    LeoPluginManifest(id: usageID, name: "Usage", version: "1.0.0", apiVersion: 2, main: "main.js", permissions: permissions)
}

private func registryWithUsage() -> LeoPluginRegistry {
    var registry = LeoPluginRegistry()
    registry.registerDev(usageManifest(), path: "/tmp/usage")
    return registry
}

extension LeoPluginRegistryTests {
    @Test func aRegistrySavedBeforeCredentialGrantsExistedStillLoads() throws {
        var registry = registryWithUsage()
        _ = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/.codex", id: "g1")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)) as? [String: Any])
        var records = try #require(json["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "credentialGrants")
        json["records"] = records

        let decoded = try JSONDecoder().decode(LeoPluginRegistry.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.grants(for: usageID).isEmpty)
    }

    @Test func grantsAreAddedListedPersistedAndRemoved() throws {
        var registry = registryWithUsage()
        let claudeAdded = registry.addGrant(pluginID: usageID, kind: .claudeCode, path: "/Users/a/.claude-work/", id: "g1")
        let claude = try #require(claudeAdded)
        let codexAdded = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/.codex", id: "g2")
        let codex = try #require(codexAdded)
        #expect(claude.path == "/Users/a/.claude-work")
        #expect(registry.grants(for: usageID) == [claude, codex])

        let reloaded = try JSONDecoder().decode(LeoPluginRegistry.self, from: JSONEncoder().encode(registry))
        #expect(reloaded.grants(for: usageID) == [claude, codex])

        registry.removeGrant(pluginID: usageID, grantID: "g1")
        #expect(registry.grants(for: usageID) == [codex])
    }

    @Test func addingTheSameAccountTwiceReturnsTheExistingGrant() throws {
        var registry = registryWithUsage()
        let firstAdded = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/.codex", id: "g1")
        let first = try #require(firstAdded)
        let againAdded = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/./.codex/", id: "g2")
        let again = try #require(againAdded)
        #expect(again == first)
        #expect(registry.grants(for: usageID).count == 1)
    }

    @Test func aGrantForAnUnapprovedKindOrUnknownPluginIsRefused() {
        var registry = LeoPluginRegistry()
        registry.registerDev(usageManifest(LeoPluginPermissions(network: ["chatgpt.com"], credentials: [.codex])), path: "/tmp/usage")
        #expect(registry.addGrant(pluginID: usageID, kind: .claudeCode, path: "/Users/a/.claude", id: "g1") == nil)
        #expect(registry.addGrant(pluginID: "studio.nobody", kind: .codex, path: "/Users/a/.codex", id: "g2") == nil)
        #expect(registry.grants(for: usageID).isEmpty)
    }

    @Test func approvingNarrowerPermissionsRevokesGrantsOfDroppedKinds() throws {
        var registry = registryWithUsage()
        let claudeAdded = registry.addGrant(pluginID: usageID, kind: .claudeCode, path: "/Users/a/.claude", id: "g1")
        let claude = try #require(claudeAdded)
        _ = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/.codex", id: "g2")

        registry.approve(usageID, permissions: LeoPluginPermissions(network: ["api.anthropic.com"], credentials: [.claudeCode]))
        #expect(registry.grants(for: usageID) == [claude])
    }

    @Test func reRegisteringThePluginKeepsGrantsForKindsItStillHas() throws {
        var registry = registryWithUsage()
        let codexAdded = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/.codex", id: "g2")
        let codex = try #require(codexAdded)
        _ = registry.addGrant(pluginID: usageID, kind: .claudeCode, path: "/Users/a/.claude", id: "g1")

        registry.registerDev(usageManifest(LeoPluginPermissions(network: ["chatgpt.com"], credentials: [.codex])), path: "/tmp/usage")
        #expect(registry.grants(for: usageID) == [codex])
    }

    @Test func aHandleShowsTheFolderNameAndAHomeRelativePath() {
        let grant = LeoPluginCredentialGrant(id: "g1", kind: .claudeCode, path: "/Users/evan/.claude-blackpaw-leo")
        let handle = grant.handle(home: "/Users/evan")
        #expect(handle == LeoPluginCredentialHandle(id: "g1", kind: .claudeCode, label: ".claude-blackpaw-leo", path: "~/.claude-blackpaw-leo"))
        #expect(LeoPluginCredentialGrant(id: "g2", kind: .codex, path: "/opt/codex").handle(home: "/Users/evan").path == "/opt/codex")
        // A sibling that only shares the home prefix is not inside it.
        #expect(LeoPluginCredentialGrant(id: "g3", kind: .codex, path: "/Users/evanx/.codex").handle(home: "/Users/evan").path == "/Users/evanx/.codex")
    }

    @Test(arguments: [
        ("~/.claude", "/Users/a/.claude"), ("/Users/a/.claude/", "/Users/a/.claude"), ("/Users/a/./x/../.codex", "/Users/a/.codex"),
        ("~", "/Users/a"), ("/", "/"),
    ])
    func accountPathsAreStandardized(_ raw: String, _ expected: String) {
        #expect(LeoPluginCredentialPath.standardize(raw, home: "/Users/a") == expected)
    }

    @Test func relativePathsAreNotAccountPaths() {
        #expect(LeoPluginCredentialPath.standardize("claude", home: "/Users/a") == nil)
        #expect(LeoPluginCredentialPath.standardize("", home: "/Users/a") == nil)
    }
}

// MARK: Remote machines

private let dionysus = LeoHostID.remote("Dionysus")

extension LeoPluginRegistryTests {
    @Test func aGrantStoredBeforeMachinesExistedDecodesAsThisMac() throws {
        let legacy = Data(#"{"id":"g1","kind":"codex","path":"/Users/a/.codex"}"#.utf8)
        let grant = try JSONDecoder().decode(LeoPluginCredentialGrant.self, from: legacy)
        #expect(grant.machine == .local)
        #expect(grant == LeoPluginCredentialGrant(id: "g1", kind: .codex, path: "/Users/a/.codex"))
    }

    @Test func aRemoteGrantSurvivesAnEncodeDecodeRoundTrip() throws {
        let grant = LeoPluginCredentialGrant(id: "g1", kind: .claudeCode, path: "/Users/evan/.claude", machine: dionysus)
        let decoded = try JSONDecoder().decode(LeoPluginCredentialGrant.self, from: JSONEncoder().encode(grant))
        #expect(decoded == grant)
        #expect(decoded.machine == dionysus)
    }

    @Test func theSameFolderOnTwoMachinesIsTwoGrants() throws {
        var registry = registryWithUsage()
        let localAdded = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/.codex", id: "g1")
        let remoteAdded = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/.codex", id: "g2", machine: dionysus)
        let againAdded = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/./.codex/", id: "g3", machine: dionysus)
        let local = try #require(localAdded)
        let remote = try #require(remoteAdded)
        let again = try #require(againAdded)
        #expect(local.machine == .local)
        #expect(remote.machine == dionysus && remote.id == "g2")
        #expect(again == remote)
        #expect(registry.grants(for: usageID).count == 2)
    }

    @Test func aLocalHandleOmitsTheMachineAndARemoteHandleNamesIt() {
        let local = LeoPluginCredentialGrant(id: "g1", kind: .codex, path: "/Users/evan/.codex").handle(home: "/Users/evan")
        #expect(local.machine == nil)
        // The remote path is shown as the daemon listed it: this Mac's home says nothing about that machine's.
        let remote = LeoPluginCredentialGrant(id: "g2", kind: .codex, path: "/Users/evan/.codex", machine: dionysus).handle(home: "/Users/evan")
        #expect(remote.machine == "Dionysus")
        #expect(remote.path == "/Users/evan/.codex")
        #expect(remote.label == ".codex")
    }
}
