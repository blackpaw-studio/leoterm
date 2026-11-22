import Foundation
import Testing

@testable import LeoKit

/// Manifest v2: the `credentials` permission and its bound-host rule.
extension LeoPluginManifestTests {
    static func usageObject(
        apiVersion: Int = 2, network: [String] = ["api.anthropic.com", "chatgpt.com"], credentials: [Any] = ["claude-code", "codex"]
    ) -> [String: Any] {
        [
            "id": "studio.blackpaw.usage", "name": "Usage", "version": "1.0.0", "apiVersion": apiVersion, "main": "dist/main.js",
            "permissions": ["network": network, "secrets": true, "credentials": credentials],
        ]
    }

    @Test func aV1ManifestWithoutCredentialsStillValidates() throws {
        guard case .valid(let manifest) = Self.validate(Self.goodObject()) else {
            Issue.record("v1 manifest refused")
            return
        }
        #expect(manifest.apiVersion == 1)
        #expect(manifest.permissions.credentials.isEmpty)
    }

    @Test func aV2ManifestDecodesCredentialKinds() throws {
        guard case .valid(let manifest) = Self.validate(Self.usageObject()) else {
            Issue.record("v2 manifest refused")
            return
        }
        #expect(manifest.permissions.credentials == [.claudeCode, .codex])
        #expect(LeoPluginCredentialKind.claudeCode.boundHost == "api.anthropic.com")
        #expect(LeoPluginCredentialKind.codex.boundHost == "chatgpt.com")
    }

    @Test func credentialsOnAV1ManifestAreRefusedWithTheReason() {
        let reason = Self.refusal(Self.usageObject(apiVersion: 1))
        #expect(reason.contains("credentials"))
        #expect(reason.contains("requires API version 2"))
    }

    @Test func anUnknownCredentialKindIsRefused() {
        let reason = Self.refusal(Self.usageObject(credentials: ["claude-code", "gemini"]))
        #expect(reason.contains("unknown credential kind 'gemini'"))
    }

    @Test func aDuplicateCredentialKindIsRefused() {
        let reason = Self.refusal(Self.usageObject(credentials: ["codex", "codex"]))
        #expect(reason.contains("'codex' more than once"))
    }

    @Test func aCredentialKindWithoutItsBoundHostIsRefused() {
        let reason = Self.refusal(Self.usageObject(network: ["chatgpt.com"]))
        #expect(reason.contains("claude-code"))
        #expect(reason.contains("api.anthropic.com"))
    }

    @Test func aWildcardDoesNotSatisfyABoundHost() {
        let reason = Self.refusal(Self.usageObject(network: ["*.anthropic.com", "chatgpt.com"]))
        #expect(reason.contains("api.anthropic.com"))
    }

    @Test func apiVersionThreeIsRefused() {
        let reason = Self.refusal(Self.usageObject(apiVersion: 3))
        #expect(reason.contains("API version 3"))
        #expect(reason.contains("supports 2"))
    }

    @Test func permissionsWithoutCredentialsEncodeWithoutTheKey() throws {
        // registry.json must stay readable by an older Leo, whose strict decode
        // refuses unknown permission keys.
        let data = try JSONEncoder().encode(LeoPluginPermissions(network: ["a.example.com"]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["credentials"] == nil)
        let granted = LeoPluginPermissions(network: ["chatgpt.com"], credentials: [.codex])
        #expect(try JSONDecoder().decode(LeoPluginPermissions.self, from: JSONEncoder().encode(granted)) == granted)
    }
}

extension LeoPluginApprovalReviewTests {
    @Test func aFreshInstallListsEachCredentialKind() {
        let permissions = LeoPluginPermissions(network: ["chatgpt.com"], credentials: [.claudeCode, .codex])
        let request = LeoPluginApprovalRequest(
            id: "studio.blackpaw.usage", name: "Usage", version: "1.0.0", sha: nil, sourceDescription: "/tmp/usage",
            permissions: permissions, diff: nil, isDev: true)
        let credentialLines = request.permissionLines.filter { $0.hasPrefix("Accounts:") }
        #expect(credentialLines.count == 2)
        #expect(credentialLines.contains { $0.contains("Claude Code") })
        #expect(credentialLines.contains { $0.contains("Codex") })
    }

    @Test func anUpdateAddingCodexShowsOnlyTheNewKind() throws {
        let old = LeoPluginPermissions(network: ["api.anthropic.com", "chatgpt.com"], credentials: [.claudeCode])
        let new = LeoPluginPermissions(network: ["api.anthropic.com", "chatgpt.com"], credentials: [.claudeCode, .codex])
        let diff = LeoPluginPermissionDiff(old: old, new: new)
        #expect(diff.addedCredentials == [.codex])
        #expect(!diff.isEmpty)
        #expect(LeoPluginPermissionDiff(old: new, new: old).isEmpty)

        let request = LeoPluginApprovalRequest(
            id: "studio.blackpaw.usage", name: "Usage", version: "1.1.0", sha: nil, sourceDescription: "/tmp/usage",
            permissions: new, diff: diff, isDev: true)
        #expect(request.permissionLines.count == 1)
        #expect(request.permissionLines[0].contains("Codex"))
    }
}

extension LeoPluginRegistryTests {
    @Test func anUpgradeThatAddsCodexShowsInTheDiff() throws {
        var registry = LeoPluginRegistry()
        let old = LeoPluginPermissions(network: ["api.anthropic.com", "chatgpt.com"], credentials: [.claudeCode])
        registry.registerDev(
            LeoPluginManifest(id: "studio.blackpaw.usage", name: "Usage", version: "1.0.0", apiVersion: 2, main: "main.js", permissions: old),
            path: "/tmp/usage")
        let new = LeoPluginPermissions(network: old.network, credentials: [.claudeCode, .codex])
        let diff = try #require(registry.upgradeDiff(id: "studio.blackpaw.usage", to: new))
        #expect(diff.addedCredentials == [.codex])
    }
}
