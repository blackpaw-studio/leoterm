import Foundation
import Testing

@testable import LeoKit

/// Guards the first-party GitHub plugin shipped in `macos/Bundled/Plugins`.
/// The ids mirror `plugins/github/src/config.ts` (checked there by `test/manifest.test.ts`).
struct LeoBundledGitHubManifestTests {
    /// `Packages/LeoKit/Tests/LeoKitTests/Plugins/<this file>` → repo root.
    static let pluginDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("macos/Bundled/Plugins/studio.blackpaw.github")

    static func manifest() throws -> LeoPluginManifest {
        let data = try Data(contentsOf: pluginDirectory.appendingPathComponent("leo-plugin.json"))
        guard case .valid(let manifest) = LeoPluginManifestValidator.validate(data) else {
            throw ManifestRefused()
        }
        return manifest
    }

    struct ManifestRefused: Error {}

    @Test func theValidatorAcceptsTheShippedManifest() throws {
        let manifest = try Self.manifest()
        #expect(manifest.id == "studio.blackpaw.github")
        #expect(manifest.apiVersion == LeoPluginAPI.supported)
    }

    @Test func networkHostsAreExactlyTheSpecsFour() throws {
        let network = try Self.manifest().permissions.network
        #expect(network == ["github.com", "api.github.com", "*.actions.githubusercontent.com", "*.blob.core.windows.net"])
    }

    @Test func permissionsAndContributionIdsMatchTheCode() throws {
        let manifest = try Self.manifest()
        #expect(manifest.permissions.secrets)
        #expect(manifest.permissions.agents == [.read, .send, .spawn])
        #expect(manifest.contributes.views.map(\.id) == ["github"])
        #expect(manifest.contributes.rowAccessories.map(\.id) == ["pr"])
        #expect(manifest.contributes.sidebarSections.map(\.id) == ["assigned-issues"])
        #expect(
            manifest.contributes.commands.map(\.id)
                == ["new-agent-from-issue", "open-pr", "create-pr", "sign-in", "sign-out"])
    }

    @Test func theManifestsMainIsTheCommittedBundle() throws {
        let manifest = try Self.manifest()
        #expect(manifest.main == "main.js")
        let bundle = try String(contentsOf: Self.pluginDirectory.appendingPathComponent(manifest.main), encoding: .utf8)
        #expect(bundle.count > 1_000)
        #expect(!bundle.contains("sourceMappingURL"))
    }
}
