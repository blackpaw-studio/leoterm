import Testing
import Foundation
@testable import Ghostty

struct LeoObserveConfigTests {
    // MARK: parseWebConfig

    @Test func parsesPortFromStandardIndentation() {
        let yaml = """
        defaults:
            model: opus
        web:
            enabled: true
            port: 8370
            bind: 0.0.0.0
        """
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: 8370))
    }

    @Test func parsesPortWithDifferentIndentationWidth() {
        let yaml = """
        web:
          port: 9999
          enabled: true
        """
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: 9999))
    }

    @Test func parsesPortWithTabIndentation() {
        let yaml = "web:\n\tport: 4242\n\tenabled: true\n"
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: 4242))
    }

    @Test func missingWebBlockDefaultsToEnabledDefaultPort() {
        let yaml = """
        defaults:
            model: opus
        tasks:
            foo:
                schedule: 0 9 * * *
        """
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: LeoObserveConfigParsing.defaultPort))
    }

    @Test func missingPortKeyDefaultsToDefaultPort() {
        let yaml = """
        web:
            enabled: true
            bind: 0.0.0.0
        """
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: LeoObserveConfigParsing.defaultPort))
    }

    @Test func enabledFalseDisablesRegardlessOfPort() {
        let yaml = """
        web:
            enabled: false
            port: 8370
        """
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .disabled)
    }

    @Test func doesNotConfuseNestedListItemsForKeys() {
        // `allowed_hosts` list items shouldn't be mistaken for `port:`/`enabled:`.
        let yaml = """
        web:
            enabled: true
            port: 8370
            allowed_hosts:
                - 10.0.4.16
                - 10.0.2.10
        api_clients:
            hr-bot:
                port: 1
        """
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: 8370))
    }

    @Test func ignoresInlineCommentsAndQuotes() {
        let yaml = """
        web:
            enabled: true
            port: "8370" # comment
        """
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: 8370))
    }

    @Test func nonNumericPortFallsBackToDefault() {
        let yaml = """
        web:
            enabled: true
            port: not-a-number
        """
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: LeoObserveConfigParsing.defaultPort))
    }

    @Test func emptyYamlDefaultsToEnabledDefaultPort() {
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: "") == .enabled(port: LeoObserveConfigParsing.defaultPort))
    }

    @Test func nestedSubMappingPortDoesNotShadowOwnPortKey() {
        // `cors.port` is nested one level deeper than the block's own keys;
        // the block's own `port:` (8370) must win, not the nested one (1).
        let yaml = "web:\n  cors:\n    port: 1\n  port: 8370"
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: 8370))
    }

    @Test func nestedSubMappingEnabledDoesNotShadowOwnEnabledKey() {
        // `auth.enabled` is nested; the block's own `enabled: true` must win,
        // not the nested `false`.
        let yaml = "web:\n  auth:\n    enabled: false\n  enabled: true"
        #expect(LeoObserveConfigParsing.parseWebConfig(yamlContent: yaml) == .enabled(port: LeoObserveConfigParsing.defaultPort))
    }

    // MARK: parseToken

    @Test func parsesTokenTrimmingWhitespaceAndNewline() {
        #expect(LeoObserveConfigParsing.parseToken(fileContent: "abc123\n") == "abc123")
        #expect(LeoObserveConfigParsing.parseToken(fileContent: "  abc123  \n") == "abc123")
    }

    @Test func emptyTokenFileYieldsNil() {
        #expect(LeoObserveConfigParsing.parseToken(fileContent: "") == nil)
        #expect(LeoObserveConfigParsing.parseToken(fileContent: "   \n") == nil)
    }

    // MARK: LeoObserveConfigLoader (thin loader, using real temp files)

    @Test func loaderCombinesYamlAndTokenIntoConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let yamlPath = dir.appendingPathComponent("leo.yaml")
        let tokenPath = dir.appendingPathComponent("api.token")
        try "web:\n    enabled: true\n    port: 1234\n".write(to: yamlPath, atomically: true, encoding: .utf8)
        try "sekret\n".write(to: tokenPath, atomically: true, encoding: .utf8)

        let config = LeoObserveConfigLoader.load(leoYamlPath: yamlPath.path, tokenPath: tokenPath.path)
        #expect(config == LeoObserveConfig(baseURL: URL(string: "http://127.0.0.1:1234")!, token: "sekret"))
    }

    @Test func loaderReturnsNilWhenWebDisabled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let yamlPath = dir.appendingPathComponent("leo.yaml")
        let tokenPath = dir.appendingPathComponent("api.token")
        try "web:\n    enabled: false\n".write(to: yamlPath, atomically: true, encoding: .utf8)
        try "sekret\n".write(to: tokenPath, atomically: true, encoding: .utf8)

        #expect(LeoObserveConfigLoader.load(leoYamlPath: yamlPath.path, tokenPath: tokenPath.path) == nil)
    }

    @Test func loaderReturnsNilWhenTokenMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let yamlPath = dir.appendingPathComponent("leo.yaml")
        let missingTokenPath = dir.appendingPathComponent("does-not-exist.token")
        try "web:\n    enabled: true\n    port: 8370\n".write(to: yamlPath, atomically: true, encoding: .utf8)

        #expect(LeoObserveConfigLoader.load(leoYamlPath: yamlPath.path, tokenPath: missingTokenPath.path) == nil)
    }

    @Test func loaderReturnsNilWhenYamlMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missingYamlPath = dir.appendingPathComponent("does-not-exist.yaml")
        let tokenPath = dir.appendingPathComponent("api.token")
        try "sekret\n".write(to: tokenPath, atomically: true, encoding: .utf8)

        #expect(LeoObserveConfigLoader.load(leoYamlPath: missingYamlPath.path, tokenPath: tokenPath.path) == nil)
    }
}
