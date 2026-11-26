import Foundation
import Testing

@testable import LeoKit

private let usageID = "studio.blackpaw.usage"
private let deepseek = LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.deepseek.com")
private let withKeys = LeoPluginPermissions(
    network: ["api.deepseek.com", "api.evil.com", "chatgpt.com"], credentials: [.codex], apiKeys: [deepseek])

private func registry(_ permissions: LeoPluginPermissions = withKeys) -> LeoPluginRegistry {
    var registry = LeoPluginRegistry()
    registry.registerDev(
        LeoPluginManifest(id: usageID, name: "Usage", version: "1.0.0", apiVersion: 2, main: "main.js", permissions: permissions),
        path: "/tmp/usage")
    return registry
}

private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

/// `api-key` grants: what the registry stores (never the key) and when it drops them.
extension LeoPluginRegistryTests {
    @Test func anAPIKeyGrantEncodesItsProviderAndNameOnly() throws {
        let grant = LeoPluginCredentialGrant(id: "g1", apiKeyProvider: "deepseek", name: "Work")
        let object = try jsonObject(grant)
        #expect(Set(object.keys) == ["id", "kind", "provider", "name", "machine"])
        #expect(object["kind"] as? String == "api-key")
        #expect(object["provider"] as? String == "deepseek")
        #expect(object["name"] as? String == "Work")
        #expect(try JSONDecoder().decode(LeoPluginCredentialGrant.self, from: JSONEncoder().encode(grant)) == grant)
        #expect(grant.machine == .local)
    }

    @Test func anAccountGrantEncodesAsBefore() throws {
        let grant = LeoPluginCredentialGrant(id: "g1", kind: .codex, path: "/Users/a/.codex")
        let object = try jsonObject(grant)
        #expect(Set(object.keys) == ["id", "kind", "path", "machine"])
        #expect(object["kind"] as? String == "codex")
        let legacy = Data(#"{"id":"g1","kind":"codex","path":"/Users/a/.codex","machine":{"local":{}}}"#.utf8)
        #expect(try JSONDecoder().decode(LeoPluginCredentialGrant.self, from: legacy) == grant)
    }

    @Test func anAPIKeyGrantIsAddedForAnApprovedProviderWithoutDedupe() throws {
        var registry = registry()
        let added1 = registry.addAPIKeyGrant(pluginID: usageID, provider: "deepseek", name: "Work", id: "g1")
        let first = try #require(added1)
        let added2 = registry.addAPIKeyGrant(pluginID: usageID, provider: "deepseek", name: "Work", id: "g2")
        let second = try #require(added2)
        #expect(first.subject == .apiKey(provider: "deepseek", name: "Work"))
        #expect(registry.grants(for: usageID) == [first, second])

        let reloaded = try JSONDecoder().decode(LeoPluginRegistry.self, from: JSONEncoder().encode(registry))
        #expect(reloaded.grants(for: usageID) == [first, second])
    }

    @Test func anAPIKeyGrantForAnUnapprovedProviderOrUnknownPluginIsRefused() {
        var registry = registry()
        #expect(registry.addAPIKeyGrant(pluginID: usageID, provider: "openrouter", name: "x", id: "g1") == nil)
        #expect(registry.addAPIKeyGrant(pluginID: "studio.nobody", provider: "deepseek", name: "x", id: "g2") == nil)
        #expect(registry.grants(for: usageID).isEmpty)
    }

    @Test(arguments: ["", "   ", String(repeating: "n", count: 65), "a\nb", "a\u{7F}"])
    func anAPIKeyGrantWithABadNameIsRefused(name: String) {
        var registry = registry()
        #expect(registry.addAPIKeyGrant(pluginID: usageID, provider: "deepseek", name: name, id: "g1") == nil)
    }

    @Test func approvingWithoutTheProviderOrWithANewHostDropsItsGrants() throws {
        var registry = registry()
        let added3 = registry.addGrant(pluginID: usageID, kind: .codex, path: "/Users/a/.codex", id: "c1")
        let codex = try #require(added3)
        _ = registry.addAPIKeyGrant(pluginID: usageID, provider: "deepseek", name: "Work", id: "g1")

        let relabelled = LeoPluginPermissions(
            network: withKeys.network, credentials: [.codex],
            apiKeys: [LeoPluginAPIKeyProvider(provider: "deepseek", label: "DS", host: "api.deepseek.com")])
        registry.approve(usageID, permissions: relabelled)
        #expect(registry.grants(for: usageID).count == 2)

        let moved = LeoPluginPermissions(
            network: withKeys.network, credentials: [.codex],
            apiKeys: [LeoPluginAPIKeyProvider(provider: "deepseek", label: "DS", host: "api.evil.com")])
        registry.approve(usageID, permissions: moved)
        #expect(registry.grants(for: usageID) == [codex])

        _ = registry.addAPIKeyGrant(pluginID: usageID, provider: "deepseek", name: "Work", id: "g2")
        registry.approve(usageID, permissions: LeoPluginPermissions(network: withKeys.network, credentials: [.codex]))
        #expect(registry.grants(for: usageID) == [codex])
    }

    @Test func reRegisteringWithAChangedHostDropsTheProvidersGrants() throws {
        var registry = registry()
        let added4 = registry.addAPIKeyGrant(pluginID: usageID, provider: "deepseek", name: "Work", id: "g1")
        let kept = try #require(added4)
        registry.registerDev(
            LeoPluginManifest(id: usageID, name: "Usage", version: "1.0.1", apiVersion: 2, main: "main.js", permissions: withKeys),
            path: "/tmp/usage")
        #expect(registry.grants(for: usageID) == [kept])

        let moved = LeoPluginPermissions(
            network: withKeys.network, apiKeys: [LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.evil.com")])
        registry.registerDev(
            LeoPluginManifest(id: usageID, name: "Usage", version: "1.0.2", apiVersion: 2, main: "main.js", permissions: moved),
            path: "/tmp/usage")
        #expect(registry.grants(for: usageID).isEmpty)
    }

    @Test func theAPIKeyHandleCarriesIDKindProviderAndName() {
        let grant = LeoPluginCredentialGrant(id: "g1", apiKeyProvider: "deepseek", name: "Work")
        #expect(grant.accountHandle(home: "/Users/a") == nil)
        #expect(grant.apiKeyHandle == LeoPluginAPIKeyHandle(id: "g1", provider: "deepseek", name: "Work"))
        #expect(LeoPluginCredentialGrant(id: "c1", kind: .codex, path: "/x/.codex").apiKeyHandle == nil)
    }

    @Test func theStorePersistsAPIKeyGrants() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LeoPluginStore(root: root)
        try store.update { $0 = registry() }
        let grant = try #require(try store.addAPIKeyGrant(pluginID: usageID, provider: "deepseek", name: "Work", id: "g1"))
        #expect(LeoPluginStore(root: root).grants(pluginID: usageID) == [grant])
    }
}

extension LeoPluginCredentialsTests {
    @Test func theAccountResolverRefusesAnAPIKeyGrant() {
        let resolver = LeoPluginCredentials(keychain: PluginFakeKeychain(), files: LeoPluginCredentialFileReader(), home: "/Users/a", userName: "a")
        #expect(throws: LeoPluginCredentialError.invalid) {
            try resolver.resolve(LeoPluginCredentialGrant(id: "g1", apiKeyProvider: "deepseek", name: "Work"), allowUI: false)
        }
    }
}
