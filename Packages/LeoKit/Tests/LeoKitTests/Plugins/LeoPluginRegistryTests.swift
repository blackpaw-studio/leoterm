import Foundation
import Testing

@testable import LeoKit

private let sha1 = String(repeating: "a", count: 40)
private let sha2 = String(repeating: "b", count: 40)
private let demoURL = "https://github.com/x/demo"

private func manifest(
    id: String = "studio.blackpaw.demo", network: [String] = [], secrets: Bool = false,
    agents: [LeoPluginAgentVerb] = []
) -> LeoPluginManifest {
    LeoPluginManifest(
        id: id, name: "Demo", version: "1.0.0", apiVersion: 1, main: "main.js",
        permissions: LeoPluginPermissions(network: network, secrets: secrets, agents: agents))
}

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("leo-registry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct LeoPluginRegistryTests {
    @Test func installedPluginStoresTheApprovedPermissionsAndIsEnabled() {
        var registry = LeoPluginRegistry()
        let perms = LeoPluginPermissions(network: ["api.github.com"], secrets: true, agents: [.read])
        registry.registerInstalled(manifest(network: ["api.github.com"], secrets: true, agents: [.read]), url: demoURL, ref: "main", sha: sha1)

        let record = registry.record(for: "studio.blackpaw.demo")
        #expect(record?.enabled == true)
        #expect(record?.approvedPermissions == perms)
        #expect(record?.source == .git(url: demoURL, ref: "main", sha: sha1))
    }

    @Test func enableAndDisableToggleTheRecordAndEnablingClearsACrashNotice() {
        var registry = LeoPluginRegistry()
        registry.registerInstalled(manifest(), url: demoURL, ref: "main", sha: sha1)
        registry.setDisabled("studio.blackpaw.demo", reason: "crashed 3 times")
        #expect(registry.record(for: "studio.blackpaw.demo")?.disabledReason == "crashed 3 times")
        #expect(registry.record(for: "studio.blackpaw.demo")?.isRunnable == false)

        registry.setEnabled("studio.blackpaw.demo", true)
        #expect(registry.record(for: "studio.blackpaw.demo")?.disabledReason == nil)
        #expect(registry.record(for: "studio.blackpaw.demo")?.isRunnable == true)

        registry.setEnabled("studio.blackpaw.demo", false)
        #expect(registry.record(for: "studio.blackpaw.demo")?.isRunnable == false)
    }

    @Test func aPermissionIncreaseNeedsReapprovalAndADecreaseDoesNot() throws {
        var registry = LeoPluginRegistry()
        registry.registerInstalled(manifest(network: ["a.example.com"]), url: demoURL, ref: "main", sha: sha1)

        let more = LeoPluginPermissions(network: ["a.example.com", "b.example.com"], secrets: true, agents: [])
        let diff = try #require(registry.upgradeDiff(id: "studio.blackpaw.demo", to: more))
        #expect(diff.addedHosts == ["b.example.com"])
        #expect(diff.secretsEnabled)
        #expect(!diff.isEmpty)

        let less = LeoPluginPermissions.none
        #expect(try #require(registry.upgradeDiff(id: "studio.blackpaw.demo", to: less)).isEmpty)
        #expect(registry.upgradeDiff(id: "studio.nobody", to: less) == nil)
    }

    @Test func approveReplacesTheApprovedPermissions() {
        var registry = LeoPluginRegistry()
        registry.registerInstalled(manifest(), url: demoURL, ref: "main", sha: sha1)
        let more = LeoPluginPermissions(network: ["b.example.com"], secrets: false, agents: [.send])
        registry.approve("studio.blackpaw.demo", permissions: more)
        #expect(registry.record(for: "studio.blackpaw.demo")?.approvedPermissions == more)
        #expect(registry.upgradeDiff(id: "studio.blackpaw.demo", to: more)?.isEmpty == true)
    }

    @Test func claimsBindGitIdsToTheirSourceAndReserveBundledAndDevIds() {
        var registry = LeoPluginRegistry()
        registry.registerInstalled(manifest(), url: demoURL, ref: "main", sha: sha1)
        registry.registerBundled(manifest(id: "studio.blackpaw.builtin"))
        registry.registerDev(manifest(id: "studio.blackpaw.local"), path: "/tmp/plugin")

        #expect(registry.claim(forID: "studio.blackpaw.demo") == .installed(sourceURL: demoURL))
        #expect(registry.claim(forID: "studio.blackpaw.builtin") == .reserved)
        #expect(registry.claim(forID: "studio.blackpaw.local") == .reserved)
        #expect(registry.claim(forID: "studio.blackpaw.free") == nil)
    }

    @Test func bundledRegistrationIsPreApprovedAndNeverOverwritesAnExistingRecord() {
        var registry = LeoPluginRegistry()
        registry.registerBundled(manifest(id: "studio.blackpaw.builtin", network: ["a.example.com"]))
        let first = registry.record(for: "studio.blackpaw.builtin")
        #expect(first?.enabled == true)
        #expect(first?.approvedPermissions.network == ["a.example.com"])

        registry.registerBundled(manifest(id: "studio.blackpaw.builtin", network: ["a.example.com", "evil.example.com"]))
        #expect(registry.record(for: "studio.blackpaw.builtin")?.approvedPermissions.network == ["a.example.com"])
    }

    @Test func hiddenSectionsRoundTripThroughJSON() throws {
        var registry = LeoPluginRegistry()
        registry.registerInstalled(manifest(secrets: true), url: demoURL, ref: "main", sha: sha1)
        registry.setSection("studio.blackpaw.demo", section: "issues", hidden: true)
        registry.registerDev(manifest(id: "studio.blackpaw.local"), path: "/tmp/p")

        let decoded = try JSONDecoder().decode(LeoPluginRegistry.self, from: JSONEncoder().encode(registry))
        #expect(decoded == registry)
        #expect(decoded.record(for: "studio.blackpaw.demo")?.hiddenSections == ["issues"])
        registry.setSection("studio.blackpaw.demo", section: "issues", hidden: false)
        #expect(registry.record(for: "studio.blackpaw.demo")?.hiddenSections == [])
    }

    @Test func hiddenPanesRoundTripAndAreSetPerPlugin() throws {
        var registry = LeoPluginRegistry()
        registry.registerInstalled(manifest(secrets: true), url: demoURL, ref: "main", sha: sha1)
        registry.registerDev(manifest(id: "studio.blackpaw.local"), path: "/tmp/p")
        registry.setPane("studio.blackpaw.demo", pane: "status", hidden: true)
        registry.setPane("studio.blackpaw.demo", pane: "status", hidden: true)

        let decoded = try JSONDecoder().decode(LeoPluginRegistry.self, from: JSONEncoder().encode(registry))
        #expect(decoded == registry)
        #expect(decoded.record(for: "studio.blackpaw.demo")?.hiddenPanes == ["status"])
        #expect(decoded.record(for: "studio.blackpaw.local")?.hiddenPanes == [])
        registry.setPane("studio.blackpaw.demo", pane: "status", hidden: false)
        #expect(registry.record(for: "studio.blackpaw.demo")?.hiddenPanes == [])
    }

    @Test func aRegistrySavedBeforePanesExistedStillLoads() throws {
        var registry = LeoPluginRegistry()
        registry.registerInstalled(manifest(secrets: true), url: demoURL, ref: "main", sha: sha1)
        let encoded = try JSONEncoder().encode(registry)
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var records = try #require(json["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "hiddenPanes")
        json["records"] = records
        let old = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(LeoPluginRegistry.self, from: old)
        #expect(decoded.record(for: "studio.blackpaw.demo")?.hiddenPanes == [])
    }

    @Test func removeAndSourceSwap() {
        var registry = LeoPluginRegistry()
        registry.registerInstalled(manifest(), url: demoURL, ref: "main", sha: sha1)
        registry.setSource("studio.blackpaw.demo", .git(url: demoURL, ref: "main", sha: sha2), version: "1.1.0")
        #expect(registry.record(for: "studio.blackpaw.demo")?.source == .git(url: demoURL, ref: "main", sha: sha2))
        #expect(registry.record(for: "studio.blackpaw.demo")?.version == "1.1.0")
        registry.remove("studio.blackpaw.demo")
        #expect(registry.record(for: "studio.blackpaw.demo") == nil)
    }
}

struct LeoPluginStoreTests {
    @Test func persistsAcrossReloads() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LeoPluginStore(root: root)
        try store.update { $0.registerInstalled(manifest(), url: demoURL, ref: "main", sha: sha1) }

        let reloaded = LeoPluginStore(root: root)
        #expect(reloaded.registry.record(for: "studio.blackpaw.demo")?.source == .git(url: demoURL, ref: "main", sha: sha1))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("registry.json").path))
    }

    @Test func aCorruptRegistryIsSetAsideNotSilentlyOverwritten() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{not json".utf8).write(to: root.appendingPathComponent("registry.json"))

        let store = LeoPluginStore(root: root)
        #expect(store.registry.records.isEmpty)
        #expect(store.loadIssue != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names.contains { $0.hasPrefix("registry.corrupt-") })
    }

    @Test func aFailedWriteLeavesTheInMemoryRegistryUnchanged() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LeoPluginStore(root: root)
        try store.update { $0.registerInstalled(manifest(), url: demoURL, ref: "main", sha: sha1) }
        // A directory where the file should go makes the atomic write fail.
        try FileManager.default.removeItem(at: root.appendingPathComponent("registry.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("registry.json/x"), withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { try store.update { $0.remove("studio.blackpaw.demo") } }
        #expect(store.registry.record(for: "studio.blackpaw.demo") != nil)
    }

    @Test func theStoreIsTheInstallersIDClaimLookup() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LeoPluginStore(root: root)
        try store.update { $0.registerInstalled(manifest(), url: demoURL, ref: "main", sha: sha1) }
        let runner = ScriptedGit(sha: sha2)
        let installer = LeoPluginGitInstaller(
            root: root, runner: runner, inheritedEnvironment: [:], gitIsAvailable: { _ in true }, idClaims: store)

        // The same id from another repository is refused ...
        await #expect(throws: LeoPluginInstallError.idTakenBySource(id: "studio.blackpaw.demo", source: demoURL)) {
            try await installer.install(url: "https://github.com/evil/demo", sha: sha2)
        }
        // ... and from its own source is allowed (an update), live: no rebuild of the installer.
        let result = try await installer.install(url: demoURL, sha: sha2)
        #expect(result.sha == sha2)
        try store.update { $0.registerBundled(manifest(id: "studio.blackpaw.demo")) }
        // A bundled id stays with its owner even after the registry changes underneath.
        #expect(store.claim(forID: "studio.blackpaw.demo") == .installed(sourceURL: demoURL))
    }

    @Test func debugBuildsUseTheirOwnPluginsRoot() {
        let support = URL(fileURLWithPath: "/tmp/support")
        #expect(LeoPluginRoot.url(applicationSupport: support, isDebugBuild: false).path == "/tmp/support/Leo/Plugins")
        #expect(LeoPluginRoot.url(applicationSupport: support, isDebugBuild: true).path == "/tmp/support/Leo-Debug/Plugins")
    }
}

/// Fakes the clone: `checkout` writes a manifest and bundle into the staging dir.
private struct ScriptedGit: LeoPluginCommandRunning {
    let sha: String

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> LeoPluginCommandResult {
        var index = 0
        while index < arguments.count, arguments[index] == "-c" || arguments[index] == "-C" { index += 2 }
        let sub = index < arguments.count ? arguments[index] : ""
        if sub == "checkout", let flag = arguments.firstIndex(of: "-C") {
            let dir = URL(fileURLWithPath: arguments[flag + 1])
            let json = #"{"id":"studio.blackpaw.demo","name":"Demo","version":"1.0.0","apiVersion":1,"main":"main.js"}"#
            try Data(json.utf8).write(to: dir.appendingPathComponent("leo-plugin.json"))
            try Data("1".utf8).write(to: dir.appendingPathComponent("main.js"))
        }
        let out = sub == "rev-parse" ? Data((sha + "\n").utf8) : Data()
        return LeoPluginCommandResult(stdout: out, stderr: Data(), status: 0)
    }
}
