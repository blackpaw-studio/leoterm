import Foundation
import Testing

@testable import LeoKit

/// Manifest v2: `api-key` credential objects (provider, label, host).
extension LeoPluginManifestTests {
    static let deepseek: [String: Any] = ["kind": "api-key", "provider": "deepseek", "label": "DeepSeek", "host": "api.deepseek.com"]

    static func apiKeyObject(
        apiVersion: Int = 2, network: [String] = ["api.deepseek.com"], credentials: [Any] = [deepseek]
    ) -> [String: Any] {
        usageObject(apiVersion: apiVersion, network: network, credentials: credentials)
    }

    static func provider(_ overrides: [String: Any]) -> [String: Any] {
        deepseek.merging(overrides) { _, new in new }
    }

    @Test func anAPIKeyObjectDecodesBesideStringKinds() throws {
        let object = Self.apiKeyObject(
            network: ["api.anthropic.com", "api.deepseek.com"], credentials: ["claude-code", Self.deepseek])
        guard case .valid(let manifest) = Self.validate(object) else {
            Issue.record("manifest refused: \(Self.refusal(object))")
            return
        }
        #expect(manifest.permissions.credentials == [.claudeCode])
        #expect(
            manifest.permissions.apiKeys == [LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.deepseek.com")])
    }

    @Test func permissionsWithAPIKeysRoundTripThroughOneCredentialsArray() throws {
        let permissions = LeoPluginPermissions(
            network: ["api.anthropic.com", "api.deepseek.com"], credentials: [.claudeCode],
            apiKeys: [LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.deepseek.com")])
        let data = try JSONEncoder().encode(permissions)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let credentials = try #require(object["credentials"] as? [Any])
        #expect(credentials.count == 2)
        #expect(object["apiKeys"] == nil)
        #expect(try JSONDecoder().decode(LeoPluginPermissions.self, from: data) == permissions)
    }

    @Test func aBareAPIKeyStringIsRefused() {
        let reason = Self.refusal(Self.apiKeyObject(credentials: ["api-key"]))
        #expect(reason.contains("api-key"))
        #expect(reason.contains("object"))
    }

    @Test func anObjectFormForAnAccountKindIsRefused() {
        let reason = Self.refusal(Self.apiKeyObject(credentials: [Self.provider(["kind": "codex"])]))
        #expect(reason.contains("codex"))
    }

    @Test func anUnknownKeyInAnAPIKeyObjectIsRefused() {
        let reason = Self.refusal(Self.apiKeyObject(credentials: [Self.provider(["scheme": "bearer"])]))
        #expect(reason.contains("unknown key 'scheme'"))
    }

    @Test(arguments: ["kind", "provider", "label", "host"])
    func aMissingAPIKeyFieldIsRefused(field: String) {
        var entry = Self.deepseek
        entry[field] = nil
        let reason = Self.refusal(Self.apiKeyObject(credentials: [entry]))
        #expect(reason.contains(field))
    }

    @Test func apiKeysOnAV1ManifestAreRefused() {
        let reason = Self.refusal(Self.apiKeyObject(apiVersion: 1))
        #expect(reason.contains("requires API version 2"))
    }

    @Test(arguments: ["DeepSeek", "-deepseek", "deep_seek", "", String(repeating: "a", count: 33), "déepseek"])
    func aMalformedProviderSlugIsRefused(slug: String) {
        let reason = Self.refusal(Self.apiKeyObject(credentials: [Self.provider(["provider": slug])]))
        #expect(reason.contains("provider"))
    }

    @Test func aThirtyTwoCharacterProviderSlugIsAccepted() {
        let slug = "a" + String(repeating: "-", count: 30) + "z"
        guard case .valid = Self.validate(Self.apiKeyObject(credentials: [Self.provider(["provider": slug])])) else {
            Issue.record("32-char slug refused")
            return
        }
    }

    @Test func aDuplicateProviderIsRefused() {
        let reason = Self.refusal(Self.apiKeyObject(credentials: [Self.deepseek, Self.provider(["label": "DeepSeek 2"])]))
        #expect(reason.contains("'deepseek' more than once"))
    }

    @Test(arguments: ["", String(repeating: "x", count: 41), "Deep\nSeek", "Deep\u{7F}Seek", "   "])
    func aBadLabelIsRefused(label: String) {
        let reason = Self.refusal(Self.apiKeyObject(credentials: [Self.provider(["label": label])]))
        #expect(reason.contains("label"))
    }

    @Test(arguments: [
        "https://api.deepseek.com", "api.deepseek.com:443", "api.deepseek.com/v1", "*.deepseek.com", "127.0.0.1",
        "API.DeepSeek.com", "api.deepseek.com.", "localhost", "[::1]",
    ])
    func aMalformedHostIsRefused(host: String) {
        let reason = Self.refusal(Self.apiKeyObject(network: ["api.deepseek.com"], credentials: [Self.provider(["host": host])]))
        #expect(reason.contains("host"))
    }

    @Test func aHostMissingFromNetworkIsRefused() {
        let reason = Self.refusal(Self.apiKeyObject(network: ["api.example.com"]))
        #expect(reason.contains("api.deepseek.com"))
        #expect(reason.contains("permissions.network"))
    }

    @Test func aWildcardDoesNotSatisfyAnAPIKeyHost() {
        let reason = Self.refusal(Self.apiKeyObject(network: ["*.deepseek.com"]))
        #expect(reason.contains("api.deepseek.com"))
    }
}

extension LeoPluginPermissionEngineTests {
    @Test func theEngineAllowsOnlyApprovedAPIKeyProviders() {
        let deepseek = LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.deepseek.com")
        let engine = LeoPluginPermissionEngine(permissions: LeoPluginPermissions(network: ["api.deepseek.com"], apiKeys: [deepseek]))
        #expect(engine.check(apiKeyProvider: "deepseek") == .allowed)
        #expect(engine.apiKeyProvider("deepseek") == deepseek)
        #expect(!engine.check(apiKeyProvider: "openrouter").isAllowed)
        #expect(engine.apiKeyProvider("openrouter") == nil)
    }
}

extension LeoPluginApprovalReviewTests {
    static let deepseek = LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.deepseek.com")

    @Test func aFreshInstallListsEachAPIKeyProviderWithItsHost() {
        let permissions = LeoPluginPermissions(network: ["api.deepseek.com"], apiKeys: [Self.deepseek])
        let request = LeoPluginApprovalRequest(
            id: "studio.blackpaw.usage", name: "Usage", version: "1.0.0", sha: nil, sourceDescription: "/tmp/usage",
            permissions: permissions, diff: nil, isDev: true, trust: .notApplicable)
        #expect(request.permissionLines.contains("API keys: DeepSeek, sent only to api.deepseek.com (you paste it; it stays in Leo)"))
    }

    @Test func anUpdateAddingOrChangingAProviderNeedsApproval() {
        let base = LeoPluginPermissions(network: ["api.deepseek.com", "api.evil.com"], apiKeys: [Self.deepseek])
        #expect(LeoPluginPermissionDiff(old: base, new: base).isEmpty)

        let moved = LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.evil.com")
        let hostDiff = LeoPluginPermissionDiff(old: base, new: LeoPluginPermissions(network: base.network, apiKeys: [moved]))
        #expect(hostDiff.addedAPIKeys == [moved])
        #expect(!hostDiff.isEmpty)

        let relabelled = LeoPluginAPIKeyProvider(provider: "deepseek", label: "DS", host: "api.deepseek.com")
        let labelDiff = LeoPluginPermissionDiff(old: base, new: LeoPluginPermissions(network: base.network, apiKeys: [relabelled]))
        #expect(labelDiff.addedAPIKeys == [relabelled])

        let removed = LeoPluginPermissionDiff(old: base, new: LeoPluginPermissions(network: base.network))
        #expect(removed.isEmpty)

        let request = LeoPluginApprovalRequest(
            id: "studio.blackpaw.usage", name: "Usage", version: "1.1.0", sha: nil, sourceDescription: "/tmp/usage",
            permissions: LeoPluginPermissions(network: base.network, apiKeys: [moved]), diff: hostDiff, isDev: true,
            trust: .notApplicable)
        #expect(request.permissionLines == ["API keys: DeepSeek, sent only to api.evil.com (you paste it; it stays in Leo)"])
    }
}
