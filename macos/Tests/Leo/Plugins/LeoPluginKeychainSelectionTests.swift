import Foundation
import LeoKit
import Testing

@testable import Ghostty

/// The `LEO_PLUGIN_KEYCHAIN_FILE` seam lets an isolated debug app (whose
/// Keychain can't see the real login keychain) hold plugin secrets in a file.
/// It must exist only in Debug builds.
struct LeoPluginKeychainSelectionTests {
    private static let variable = "LEO_PLUGIN_KEYCHAIN_FILE"

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("leo-keychain-\(UUID().uuidString).json")
    }

    #if DEBUG
    @Test func theFileSeamStoresItemsPerServiceAndAccount() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let keychain = LeoPluginKeychainSelection.make(environment: [Self.variable: file.path])

        try keychain.set(service: "leo.plugin.a", account: "token", value: "one")
        try keychain.set(service: "leo.plugin.ab", account: "token", value: "two")

        #expect(try keychain.get(service: "leo.plugin.a", account: "token") == "one")
        #expect(try keychain.get(service: "leo.plugin.ab", account: "token") == "two")
        #expect(try keychain.get(service: "leo.plugin.a", account: "other") == nil)
    }

    @Test func theFileSeamDeletesOnlyTheExactService() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let keychain = LeoPluginKeychainSelection.make(environment: [Self.variable: file.path])
        try keychain.set(service: "leo.plugin.a", account: "token", value: "one")
        try keychain.set(service: "leo.plugin.ab", account: "token", value: "two")

        try keychain.deleteAll(service: "leo.plugin.a")
        try keychain.delete(service: "leo.plugin.ab", account: "missing")

        #expect(try keychain.get(service: "leo.plugin.a", account: "token") == nil)
        #expect(try keychain.get(service: "leo.plugin.ab", account: "token") == "two")
    }

    @Test func theFileSeamIsPrivateToTheUser() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let keychain = LeoPluginKeychainSelection.make(environment: [Self.variable: file.path])

        try keychain.set(service: "leo.plugin.a", account: "token", value: "one")

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func aMissingOrEmptyVariableSelectsTheSystemKeychain() {
        #expect(LeoPluginKeychainSelection.make(environment: [:]) is LeoPluginSystemKeychain)
        #expect(LeoPluginKeychainSelection.make(environment: [Self.variable: ""]) is LeoPluginSystemKeychain)
    }
    #else
    @Test func aReleaseBuildIgnoresTheVariable() {
        let keychain = LeoPluginKeychainSelection.make(environment: [Self.variable: scratchFile().path])
        #expect(keychain is LeoPluginSystemKeychain)
    }
    #endif
}
