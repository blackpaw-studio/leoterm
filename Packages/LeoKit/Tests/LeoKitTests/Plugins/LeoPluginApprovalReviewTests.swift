import Foundation
import Testing

@testable import LeoKit

struct LeoPluginApprovalReviewTests {
    private static let grown = LeoPluginPermissions(network: ["api.example.com"], secrets: true, agents: [.read])

    private static func info(source: LeoPluginSource, state: LeoPluginRunState, manifest: LeoPluginManifest?) -> LeoPluginInfo {
        LeoPluginInfo(
            id: "dev.example.demo", name: "Old Name", version: "1.0.0", source: source, isEnabled: true, state: state,
            approvedPermissions: .none, manifest: manifest, hiddenSections: [])
    }

    private static let manifest = LeoPluginManifest(
        id: "dev.example.demo", name: "Demo", version: "2.0.0", apiVersion: 1, main: "main.js", permissions: grown)

    @Test func aBundledPluginAfterAnAppUpdateShowsOnlyTheAddedPermissions() throws {
        let diff = LeoPluginPermissionDiff(old: .none, new: Self.grown)
        let request = try #require(LeoPluginApprovalRequest(
            reviewing: Self.info(source: .bundled, state: .needsApproval(diff), manifest: Self.manifest)))

        #expect(request.isUpdate)
        #expect(!request.isDev)
        #expect(request.sha == nil)
        #expect(request.version == "2.0.0")
        #expect(request.permissionLines.count == 3)
    }

    @Test func aGitPluginCarriesItsPinnedCommitAndURL() throws {
        let diff = LeoPluginPermissionDiff(old: .none, new: Self.grown)
        let sha = String(repeating: "c", count: 40)
        let request = try #require(LeoPluginApprovalRequest(
            reviewing: Self.info(
                source: .git(url: "https://github.com/acme/demo", ref: "main", sha: sha), state: .needsApproval(diff), manifest: Self.manifest)))

        #expect(request.sha == sha)
        #expect(request.sourceDescription == "https://github.com/acme/demo")
    }

    @Test func aDevPluginIsMarkedDev() throws {
        let diff = LeoPluginPermissionDiff(old: .none, new: Self.grown)
        let request = try #require(LeoPluginApprovalRequest(
            reviewing: Self.info(source: .dev(path: "/tmp/demo"), state: .needsApproval(diff), manifest: Self.manifest)))

        #expect(request.isDev)
        #expect(request.sourceDescription == "/tmp/demo")
    }

    @Test func aPluginNotWaitingOnApprovalHasNoReview() {
        #expect(LeoPluginApprovalRequest(reviewing: Self.info(source: .bundled, state: .running, manifest: Self.manifest)) == nil)
        let diff = LeoPluginPermissionDiff(old: .none, new: Self.grown)
        #expect(LeoPluginApprovalRequest(reviewing: Self.info(source: .bundled, state: .needsApproval(diff), manifest: nil)) == nil)
    }
}
