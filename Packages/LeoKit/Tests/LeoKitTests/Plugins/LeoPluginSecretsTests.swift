import Foundation
import Testing

@testable import LeoKit

/// An in-memory keychain keyed like the real one: (service, account).
private final class FakeKeychain: LeoPluginKeychain, @unchecked Sendable {
    struct Key: Hashable { let service: String; let account: String }
    private let lock = NSLock()
    private var items: [Key: String] = [:]
    var failNextWith: Error?

    var all: [Key: String] { lock.withLock { items } }

    func get(service: String, account: String) throws -> String? {
        try lock.withLock {
            if let failNextWith { throw failNextWith }
            return items[Key(service: service, account: account)]
        }
    }
    func set(service: String, account: String, value: String) throws {
        lock.withLock { items[Key(service: service, account: account)] = value }
    }
    func delete(service: String, account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: Key(service: service, account: account)) }
    }
    func deleteAll(service: String) throws {
        lock.withLock { items = items.filter { $0.key.service != service } }
    }
}

private func engine(secrets: Bool) -> LeoPluginPermissionEngine {
    LeoPluginPermissionEngine(permissions: LeoPluginPermissions(secrets: secrets))
}

struct LeoPluginSecretsTests {
    @Test func storesUnderServiceLeoPluginIdAndAccountKey() throws {
        let keychain = FakeKeychain()
        let secrets = try LeoPluginSecrets(pluginID: "studio.blackpaw.github", engine: engine(secrets: true), keychain: keychain)
        try secrets.set(key: "token", value: "abc")
        #expect(keychain.all == [.init(service: "leo.plugin.studio.blackpaw.github", account: "token"): "abc"])
        #expect(try secrets.get(key: "token") == "abc")
        try secrets.delete(key: "token")
        #expect(try secrets.get(key: "token") == nil)
    }

    @Test func missingKeyReadsAsNil() throws {
        let secrets = try LeoPluginSecrets(pluginID: "studio.blackpaw.github", engine: engine(secrets: true), keychain: FakeKeychain())
        #expect(try secrets.get(key: "nope") == nil)
    }

    @Test func pluginsNeverSeeEachOthersItems() throws {
        let keychain = FakeKeychain()
        let a = try LeoPluginSecrets(pluginID: "studio.blackpaw.a", engine: engine(secrets: true), keychain: keychain)
        let b = try LeoPluginSecrets(pluginID: "studio.blackpaw.a.b", engine: engine(secrets: true), keychain: keychain)
        try a.set(key: "k", value: "from-a")
        #expect(try b.get(key: "k") == nil)
    }

    @Test func uninstallDeletesOnlyThatPluginsExactService() throws {
        let keychain = FakeKeychain()
        let a = try LeoPluginSecrets(pluginID: "studio.blackpaw.a", engine: engine(secrets: true), keychain: keychain)
        let ab = try LeoPluginSecrets(pluginID: "studio.blackpaw.a.b", engine: engine(secrets: true), keychain: keychain)
        try a.set(key: "one", value: "1")
        try a.set(key: "two", value: "2")
        try ab.set(key: "one", value: "x")
        try a.removeAll()
        #expect(keychain.all == [.init(service: "leo.plugin.studio.blackpaw.a.b", account: "one"): "x"])
    }

    @Test func uninstallCleanupWorksEvenWithoutTheSecretsPermission() throws {
        let keychain = FakeKeychain()
        try keychain.set(service: "leo.plugin.studio.blackpaw.a", account: "k", value: "v")
        let secrets = try LeoPluginSecrets(pluginID: "studio.blackpaw.a", engine: engine(secrets: false), keychain: keychain)
        try secrets.removeAll()
        #expect(keychain.all.isEmpty)
    }

    @Test(arguments: ["", "a b", "a/b", "a:b", "é", "a\0b", String(repeating: "x", count: 65), "a*", "../x"])
    func refusesKeysOutsideTheAllowedPattern(key: String) throws {
        let keychain = FakeKeychain()
        let secrets = try LeoPluginSecrets(pluginID: "studio.blackpaw.a", engine: engine(secrets: true), keychain: keychain)
        #expect(throws: LeoPluginSecretsError.self) { try secrets.set(key: key, value: "v") }
        #expect(throws: LeoPluginSecretsError.self) { _ = try secrets.get(key: key) }
        #expect(throws: LeoPluginSecretsError.self) { try secrets.delete(key: key) }
        #expect(keychain.all.isEmpty)
    }

    @Test(arguments: ["a", "A.b_c-d", "0", String(repeating: "x", count: 64)])
    func acceptsValidKeys(key: String) throws {
        let secrets = try LeoPluginSecrets(pluginID: "studio.blackpaw.a", engine: engine(secrets: true), keychain: FakeKeychain())
        try secrets.set(key: key, value: "v")
        #expect(try secrets.get(key: key) == "v")
    }

    @Test func everyOperationRequiresTheSecretsPermission() throws {
        let keychain = FakeKeychain()
        let secrets = try LeoPluginSecrets(pluginID: "studio.blackpaw.a", engine: engine(secrets: false), keychain: keychain)
        #expect(throws: LeoPluginSecretsError.self) { try secrets.set(key: "k", value: "v") }
        #expect(throws: LeoPluginSecretsError.self) { _ = try secrets.get(key: "k") }
        #expect(throws: LeoPluginSecretsError.self) { try secrets.delete(key: "k") }
        #expect(keychain.all.isEmpty)
    }

    @Test func refusesOversizedValues() throws {
        let secrets = try LeoPluginSecrets(pluginID: "studio.blackpaw.a", engine: engine(secrets: true), keychain: FakeKeychain())
        try secrets.set(key: "k", value: String(repeating: "x", count: LeoPluginSecrets.maxValueBytes))
        #expect(throws: LeoPluginSecretsError.self) {
            try secrets.set(key: "k", value: String(repeating: "x", count: LeoPluginSecrets.maxValueBytes + 1))
        }
    }

    @Test(arguments: ["", "x", "Studio.blackpaw.x", "a..b", "a.b/c", "../a.b", "a.b\0"])
    func refusesAPluginIdThatIsNotReverseDNS(id: String) {
        #expect(throws: LeoPluginSecretsError.self) {
            _ = try LeoPluginSecrets(pluginID: id, engine: engine(secrets: true), keychain: FakeKeychain())
        }
    }

    @Test func keychainFailuresBecomeReadableErrors() throws {
        let keychain = FakeKeychain()
        keychain.failNextWith = LeoPluginKeychainError.status(-25293)
        let secrets = try LeoPluginSecrets(pluginID: "studio.blackpaw.a", engine: engine(secrets: true), keychain: keychain)
        #expect(throws: LeoPluginSecretsError.self) { _ = try secrets.get(key: "k") }
    }
}
