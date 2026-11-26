import Foundation
import Testing

@testable import LeoKit

/// The Keychain side of `api-key` credentials. No real Keychain: the fake
/// stands in for both the writer and the no-UI reader.
struct LeoPluginAPIKeyVaultTests {
    static let key = "sk-test-0123456789abcdef"
    static let plugin = "studio.blackpaw.usage"
    static let service = "Leo Plugin API Key"

    let keychain = PluginFakeKeychain()
    var vault: LeoPluginAPIKeyVault { LeoPluginAPIKeyVault(reader: keychain, writer: keychain) }

    @Test func normalizeTrimsSurroundingWhitespace() {
        #expect(LeoPluginAPIKeyVault.normalize("  \(Self.key)\n") == Self.key)
    }

    @Test(arguments: ["", "   \n", "sk test", "sk\ttest", "sk-tëst", "sk-\u{7F}x", "sk-\u{01}x"])
    func normalizeRefusesEmptyWhitespaceOrNonPrintableASCII(raw: String) {
        #expect(LeoPluginAPIKeyVault.normalize(raw) == nil)
    }

    @Test func normalizeCapsTheKeyAt512Bytes() {
        #expect(LeoPluginAPIKeyVault.normalize(String(repeating: "k", count: 512)) != nil)
        #expect(LeoPluginAPIKeyVault.normalize(String(repeating: "k", count: 513)) == nil)
    }

    @Test func saveStoresTheKeyUnderThePluginAndGrantAccount() throws {
        try vault.save(Self.key, pluginID: Self.plugin, grantID: "g1")
        #expect(keychain.items == ["\(Self.service)|\(Self.plugin)/g1": Self.key])
        #expect(LeoPluginAPIKeyVault.service == Self.service)
    }

    @Test func saveRefusesAKeyThatIsNotNormalized() {
        #expect(throws: LeoPluginAPIKeyVaultError.invalidKey) { try vault.save(" \(Self.key)", pluginID: Self.plugin, grantID: "g1") }
        #expect(keychain.items.isEmpty)
    }

    @Test func saveRefusesAnIDThatCouldAliasAnotherAccount() {
        #expect(throws: LeoPluginAPIKeyVaultError.invalidAccount) { try vault.save(Self.key, pluginID: "../x", grantID: "g1") }
        #expect(throws: LeoPluginAPIKeyVaultError.invalidAccount) { try vault.save(Self.key, pluginID: Self.plugin, grantID: "a/b") }
        #expect(keychain.items.isEmpty)
    }

    @Test func theCredentialIsABearerHeaderBoundToTheHost() throws {
        try vault.save(Self.key, pluginID: Self.plugin, grantID: "g1")
        let credential = try vault.credential(pluginID: Self.plugin, grantID: "g1", host: "api.deepseek.com", allowUI: false)
        #expect(credential.boundHost == "api.deepseek.com")
        #expect(credential.headers == ["Authorization": "Bearer \(Self.key)"])
    }

    @Test func aMissingItemIsCredentialInvalid() {
        #expect(throws: LeoPluginCredentialError.notFound) {
            try vault.credential(pluginID: Self.plugin, grantID: "gone", host: "api.deepseek.com", allowUI: false)
        }
        #expect(LeoPluginCredentialError.notFound.code == "credentialInvalid")
    }

    @Test func aStoredValueThatIsNotASafeKeyIsCredentialInvalid() throws {
        try keychain.set(service: Self.service, account: "\(Self.plugin)/g1", value: "bad\r\nX-Evil: 1")
        #expect(throws: LeoPluginCredentialError.invalid) {
            try vault.credential(pluginID: Self.plugin, grantID: "g1", host: "api.deepseek.com", allowUI: false)
        }
    }

    @Test func aReadThatNeedsUIWithoutPermissionIsNeedsAuthorization() throws {
        try vault.save(Self.key, pluginID: Self.plugin, grantID: "g1")
        keychain.requireUI(service: Self.service, account: "\(Self.plugin)/g1")
        #expect(throws: LeoPluginCredentialError.needsAuthorization) {
            try vault.credential(pluginID: Self.plugin, grantID: "g1", host: "api.deepseek.com", allowUI: false)
        }
        let allowed = try vault.credential(pluginID: Self.plugin, grantID: "g1", host: "api.deepseek.com", allowUI: true)
        #expect(allowed.headers["Authorization"] == "Bearer \(Self.key)")
    }

    @Test func deleteRemovesOnlyThatGrantsItem() throws {
        try vault.save(Self.key, pluginID: Self.plugin, grantID: "g1")
        try vault.save(Self.key, pluginID: Self.plugin, grantID: "g2")
        try vault.delete(pluginID: Self.plugin, grantID: "g1")
        #expect(Array(keychain.items.keys) == ["\(Self.service)|\(Self.plugin)/g2"])
    }

    @Test func deleteAllSweepsOnlyThisPluginsItems() throws {
        try vault.save(Self.key, pluginID: Self.plugin, grantID: "g1")
        try vault.save(Self.key, pluginID: "studio.blackpaw.usage2", grantID: "g2")
        try vault.save(Self.key, pluginID: "studio.blackpaw.usage.extra", grantID: "g3")
        try keychain.set(service: "leo.plugin.\(Self.plugin)", account: "token", value: "secret")
        try vault.deleteAll(pluginID: Self.plugin)
        #expect(
            Set(keychain.items.keys) == [
                "\(Self.service)|studio.blackpaw.usage2/g2", "\(Self.service)|studio.blackpaw.usage.extra/g3",
                "leo.plugin.\(Self.plugin)|token",
            ])
    }

    @Test func noDescriptionOfTheKeyOrItsCredentialCarriesTheKey() throws {
        let entry = LeoPluginAPIKeyEntry(key: Self.key, name: "Work")
        try vault.save(Self.key, pluginID: Self.plugin, grantID: "g1")
        let credential = try vault.credential(pluginID: Self.plugin, grantID: "g1", host: "api.deepseek.com", allowUI: false)
        let renderings = [
            String(describing: entry), String(reflecting: entry), "\(entry)", dumped(entry),
            String(describing: credential), String(reflecting: credential), dumped(credential),
        ]
        for text in renderings {
            #expect(!text.contains(Self.key), "leaked: \(text)")
            #expect(!text.contains("0123456789"))
        }
        #expect(String(describing: entry).contains("Work"))
    }

    private func dumped(_ value: Any) -> String {
        var out = ""
        dump(value, to: &out)
        return out
    }
}
