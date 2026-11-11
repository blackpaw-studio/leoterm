import Foundation
import Testing

@testable import LeoKit

private let sha1 = String(repeating: "1", count: 40)
private let sha2 = String(repeating: "2", count: 40)
private let url = "https://github.com/x/demo"
private let id = "studio.blackpaw.demo"

private struct Fixture {
    let root: URL
    let git = PluginScriptGit()
    let store: LeoPluginStore
    let installer: LeoPluginGitInstaller
    let updater: LeoPluginUpdater

    init() throws {
        root = try makeTempRoot("leo-updater")
        store = LeoPluginStore(root: root)
        installer = LeoPluginGitInstaller(
            root: root, runner: git, inheritedEnvironment: [:], gitIsAvailable: { _ in true }, idClaims: store)
        updater = LeoPluginUpdater(store: store, installer: installer, root: root)
    }

    /// An installed v1 at `sha1` whose ref `main` has moved on to `sha2`.
    func installV1(network: [String] = []) async throws {
        git.setManifest(sha: sha1, json: pluginManifestJSON(version: "1.0.0", network: network))
        git.setHead("main", sha: sha1)
        let flow = LeoPluginInstallFlow(store: store, installer: installer, root: root)
        let pending = try await flow.stage(url: url, ref: "main")
        try flow.confirm(pending)
    }

    func folder(_ sha: String) -> URL { root.appendingPathComponent("\(id)/\(sha)") }
    func exists(_ sha: String) -> Bool { FileManager.default.fileExists(atPath: folder(sha).path) }
    var record: LeoPluginRecord? { store.registry.record(for: id) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct LeoPluginUpdaterTests {
    @Test func theSameShaIsANoOp() async throws {
        let box = try Fixture()
        defer { box.cleanup() }
        try await box.installV1()
        let fetchesBefore = box.git.fetchedSHAs.count

        let outcome = try await box.updater.check(id: id)

        #expect(outcome == .upToDate(sha: sha1))
        #expect(box.git.fetchedSHAs.count == fetchesBefore)
    }

    @Test func aNewShaWithEqualPermissionsSwapsWithoutASheetAndRemovesTheOldFolder() async throws {
        let box = try Fixture()
        defer { box.cleanup() }
        try await box.installV1(network: ["api.example.com"])
        box.git.setManifest(sha: sha2, json: pluginManifestJSON(version: "1.1.0", network: ["api.example.com"]))
        box.git.setHead("main", sha: sha2)

        let outcome = try await box.updater.check(id: id)

        guard case .updated(let result) = outcome else { Issue.record("expected .updated, got \(outcome)"); return }
        #expect(result.sha == sha2)
        #expect(box.record?.source == .git(url: url, ref: "main", sha: sha2))
        #expect(box.record?.version == "1.1.0")
        #expect(box.exists(sha2))
        #expect(!box.exists(sha1))
    }

    @Test func addedPermissionsNeedApprovalAndNothingSwapsBeforeIt() async throws {
        let box = try Fixture()
        defer { box.cleanup() }
        try await box.installV1(network: ["api.example.com"])
        box.git.setManifest(sha: sha2, json: pluginManifestJSON(version: "2.0.0", network: ["api.example.com", "evil.example.com"], secrets: true))
        box.git.setHead("main", sha: sha2)

        let outcome = try await box.updater.check(id: id)

        guard case .needsApproval(let pending) = outcome else { Issue.record("expected .needsApproval, got \(outcome)"); return }
        #expect(pending.diff.addedHosts == ["evil.example.com"])
        #expect(pending.diff.secretsEnabled)
        // Nothing swapped: the record still pins sha1 with the old approval, and the old folder is intact.
        #expect(box.record?.source == .git(url: url, ref: "main", sha: sha1))
        #expect(box.record?.approvedPermissions.network == ["api.example.com"])
        #expect(box.exists(sha1))

        try box.updater.approve(pending)
        #expect(box.record?.source == .git(url: url, ref: "main", sha: sha2))
        #expect(box.record?.approvedPermissions.secrets == true)
        #expect(box.record?.approvedPermissions.network == ["api.example.com", "evil.example.com"])
        #expect(!box.exists(sha1))
        #expect(box.exists(sha2))
    }

    @Test func decliningAnUpdateRemovesTheStagedFolderAndKeepsTheOldOne() async throws {
        let box = try Fixture()
        defer { box.cleanup() }
        try await box.installV1()
        box.git.setManifest(sha: sha2, json: pluginManifestJSON(version: "2.0.0", secrets: true))
        box.git.setHead("main", sha: sha2)
        guard case .needsApproval(let pending) = try await box.updater.check(id: id) else { Issue.record("expected approval"); return }

        box.updater.discard(pending)

        #expect(!box.exists(sha2))
        #expect(box.exists(sha1))
        #expect(box.record?.source == .git(url: url, ref: "main", sha: sha1))
    }

    @Test func theUpdateInstallsTheShaItResolvedNotTheMovingRef() async throws {
        let box = try Fixture()
        defer { box.cleanup() }
        try await box.installV1()
        box.git.setManifest(sha: sha2, json: pluginManifestJSON(version: "1.1.0"))
        box.git.setHead("main", sha: sha2)

        _ = try await box.updater.check(id: id)

        // The only fetch after the install names the resolved commit.
        #expect(box.git.fetchedSHAs.last == sha2)
    }

    @Test func anUpdateThatChangesThePluginIdIsRefusedAndCleanedUp() async throws {
        let box = try Fixture()
        defer { box.cleanup() }
        try await box.installV1()
        box.git.setManifest(sha: sha2, json: pluginManifestJSON(id: "studio.blackpaw.other", version: "2.0.0"))
        box.git.setHead("main", sha: sha2)

        await #expect(throws: LeoPluginUpdateError.idChanged(expected: id, found: "studio.blackpaw.other")) {
            try await box.updater.check(id: id)
        }
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("studio.blackpaw.other").path))
        #expect(box.record?.source == .git(url: url, ref: "main", sha: sha1))
    }

    @Test func approvingAfterTheRecordMovedOnIsRefusedAsStale() async throws {
        let box = try Fixture()
        defer { box.cleanup() }
        try await box.installV1()
        box.git.setManifest(sha: sha2, json: pluginManifestJSON(version: "2.0.0", secrets: true))
        box.git.setHead("main", sha: sha2)
        guard case .needsApproval(let pending) = try await box.updater.check(id: id) else { Issue.record("expected approval"); return }
        try box.store.update { $0.remove(id) }

        #expect(throws: LeoPluginUpdateError.stale) { try box.updater.approve(pending) }
    }

    @Test func onlyGitPluginsCanBeChecked() async throws {
        let box = try Fixture()
        defer { box.cleanup() }
        try box.store.update { $0.registerBundled(LeoPluginManifest(id: id, name: "B", version: "1.0.0", apiVersion: 1, main: "main.js")) }
        await #expect(throws: LeoPluginUpdateError.notUpdatable(id)) { try await box.updater.check(id: id) }
        await #expect(throws: LeoPluginUpdateError.notUpdatable("studio.blackpaw.nope")) {
            try await box.updater.check(id: "studio.blackpaw.nope")
        }
    }
}

struct LeoPluginInstallFlowTests {
    @Test func confirmRegistersTheApprovedPermissionsAndCancelRemovesTheStagedFolder() async throws {
        let root = try makeTempRoot("leo-flow")
        defer { try? FileManager.default.removeItem(at: root) }
        let git = PluginScriptGit()
        let store = LeoPluginStore(root: root)
        let installer = LeoPluginGitInstaller(
            root: root, runner: git, inheritedEnvironment: [:], gitIsAvailable: { _ in true }, idClaims: store)
        let flow = LeoPluginInstallFlow(store: store, installer: installer, root: root)
        git.setManifest(sha: sha1, json: pluginManifestJSON(network: ["api.example.com"], secrets: true))
        git.setHead("main", sha: sha1)

        let pending = try await flow.stage(url: url, ref: "main")
        #expect(pending.request.permissions.secrets)
        #expect(store.registry.record(for: id) == nil)   // nothing registered, so nothing runs, until approval
        try flow.cancel(pending)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id)/\(sha1)").path))

        let again = try await flow.stage(url: url, ref: "main")
        try flow.confirm(again)
        #expect(store.registry.record(for: id)?.approvedPermissions.network == ["api.example.com"])
        #expect(store.registry.record(for: id)?.enabled == true)
        // Cancelling an install that is already registered must not delete the live folder.
        try flow.cancel(again)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id)/\(sha1)").path))
    }

    @Test func aDevFolderIsValidatedAndRegisteredInPlace() async throws {
        let root = try makeTempRoot("leo-flow-dev")
        defer { try? FileManager.default.removeItem(at: root) }
        let dev = root.appendingPathComponent("mine")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try Data(pluginManifestJSON(id: "studio.blackpaw.mine", secrets: true).utf8).write(to: dev.appendingPathComponent("leo-plugin.json"))
        try Data("1".utf8).write(to: dev.appendingPathComponent("main.js"))
        let store = LeoPluginStore(root: root.appendingPathComponent("plugins"))
        let flow = LeoPluginInstallFlow(
            store: store, installer: LeoPluginGitInstaller(
                root: root, runner: PluginScriptGit(), gitIsAvailable: { _ in true }, idClaims: store),
            root: root.appendingPathComponent("plugins"))

        let pending = try flow.stageDev(folder: dev)
        #expect(pending.request.isDev)
        try flow.confirmDev(pending)
        #expect(store.registry.record(for: "studio.blackpaw.mine")?.source == .dev(path: dev.path))
    }

    @Test func aDevFolderCannotTakeAnIdInstalledFromGit() async throws {
        let root = try makeTempRoot("leo-flow-dev2")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LeoPluginStore(root: root.appendingPathComponent("plugins"))
        try store.update { $0.registerInstalled(LeoPluginManifest(id: id, name: "x", version: "1.0.0", apiVersion: 1, main: "main.js"), url: url, ref: "main", sha: sha1) }
        let dev = root.appendingPathComponent("mine")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        try Data(pluginManifestJSON().utf8).write(to: dev.appendingPathComponent("leo-plugin.json"))
        try Data("1".utf8).write(to: dev.appendingPathComponent("main.js"))
        let flow = LeoPluginInstallFlow(
            store: store, installer: LeoPluginGitInstaller(
                root: root, runner: PluginScriptGit(), gitIsAvailable: { _ in true }, idClaims: store),
            root: root.appendingPathComponent("plugins"))

        #expect(throws: LeoPluginInstallError.idTakenBySource(id: id, source: url)) { try flow.stageDev(folder: dev) }
    }
}

struct LeoPluginApprovalRequestTests {
    @Test func aFreshInstallListsEveryPermissionAndAnUpdateListsOnlyTheIncreases() {
        let old = LeoPluginPermissions(network: ["a.example.com"], secrets: false, agents: [.read])
        let new = LeoPluginPermissions(network: ["a.example.com", "b.example.com"], secrets: true, agents: [.read, .send])
        func request(diff: LeoPluginPermissionDiff?) -> LeoPluginApprovalRequest {
            LeoPluginApprovalRequest(
                id: id, name: "Demo", version: "1.0.0", sha: sha1, sourceDescription: url, permissions: new, diff: diff, isDev: false)
        }

        let fresh = request(diff: nil)
        #expect(fresh.permissionLines.count == 4)
        #expect(fresh.shortSHA == String(repeating: "1", count: 7))
        #expect(!fresh.isUpdate)

        let update = request(diff: LeoPluginPermissionDiff(old: old, new: new))
        #expect(update.isUpdate)
        #expect(update.permissionLines.count == 3)
        #expect(update.permissionLines.first == "Network: b.example.com")
    }
}
