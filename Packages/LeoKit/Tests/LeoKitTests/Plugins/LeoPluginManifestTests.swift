import Foundation
import Testing

@testable import LeoKit

struct LeoPluginManifestTests {
    // MARK: - Fixtures

    /// A fully populated, valid manifest as a JSON object, so each test can
    /// mutate one field and assert on the resulting refusal.
    static func goodObject() -> [String: Any] {
        [
            "id": "studio.blackpaw.github",
            "name": "GitHub",
            "version": "1.2.3",
            "apiVersion": 1,
            "main": "dist/main.js",
            "permissions": [
                "network": ["api.github.com", "*.githubusercontent.com"],
                "secrets": true,
                "agents": ["read", "send", "spawn"],
            ],
            "contributes": [
                "views": [["id": "pr", "title": "Pull Request", "sfSymbol": "arrow.triangle.pull"]],
                "rowAccessories": [["id": "pr-status"]],
                "commands": [["id": "create-pr", "title": "Create PR", "sfSymbol": "plus"], ["id": "refresh", "title": "Refresh"]],
                "sidebarSections": [["id": "issues", "title": "Issues"]],
            ],
        ]
    }

    static func data(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func validate(_ object: [String: Any]) -> LeoPluginManifestValidation {
        LeoPluginManifestValidator.validate(data(object))
    }

    /// Returns the refusal reason, or records an issue when it validated.
    static func refusal(_ object: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) -> String {
        switch validate(object) {
        case .refused(let reason): return reason
        case .valid:
            Issue.record("expected a refusal", sourceLocation: sourceLocation)
            return ""
        }
    }

    static func mutated(_ mutate: (inout [String: Any]) -> Void) -> [String: Any] {
        var object = goodObject()
        mutate(&object)
        return object
    }

    // MARK: - Good

    @Test func aGoodManifestValidatesAndDecodesEveryField() throws {
        guard case .valid(let manifest) = Self.validate(Self.goodObject()) else {
            Issue.record("expected valid")
            return
        }
        #expect(manifest.id == "studio.blackpaw.github")
        #expect(manifest.name == "GitHub")
        #expect(manifest.version == "1.2.3")
        #expect(manifest.apiVersion == 1)
        #expect(manifest.main == "dist/main.js")
        #expect(manifest.permissions.network == ["api.github.com", "*.githubusercontent.com"])
        #expect(manifest.permissions.secrets)
        #expect(manifest.permissions.agents == [.read, .send, .spawn])
        #expect(manifest.contributes.views.map(\.id) == ["pr"])
        #expect(manifest.contributes.views.first?.sfSymbol == "arrow.triangle.pull")
        #expect(manifest.contributes.rowAccessories.map(\.id) == ["pr-status"])
        #expect(manifest.contributes.commands.map(\.id) == ["create-pr", "refresh"])
        #expect(manifest.contributes.commands.last?.sfSymbol == nil)
        #expect(manifest.contributes.sidebarSections.map(\.id) == ["issues"])
    }

    @Test func permissionsAndContributesAreOptionalAndDefaultToNothing() {
        let object = Self.mutated {
            $0.removeValue(forKey: "permissions")
            $0.removeValue(forKey: "contributes")
        }
        guard case .valid(let manifest) = Self.validate(object) else {
            Issue.record("expected valid")
            return
        }
        #expect(manifest.permissions == .none)
        #expect(manifest.contributes == .none)
    }

    @Test func prereleaseAndBuildSemverAreAccepted() {
        for version in ["0.0.1", "1.0.0-beta.1", "1.0.0+build.5", "10.20.30-rc.1+sha.abc"] {
            let object = Self.mutated { $0["version"] = version }
            guard case .valid = Self.validate(object) else {
                Issue.record("\(version) should validate")
                continue
            }
        }
    }

    // MARK: - Bad fields

    @Test(arguments: ["github", "Studio.Blackpaw.GitHub", "studio..github", ".studio.github", "studio.github.", "studio.-bad.github", "studio.bad-.github", "studio/blackpaw.github", "studio.black paw", "studio.bläckpaw.github", "", "../../etc.x"])
    func badIDsAreRefused(_ id: String) {
        let reason = Self.refusal(Self.mutated { $0["id"] = id })
        #expect(reason.contains("id"))
    }

    @Test func anIDWithATrailingNewlineIsRefused() {
        _ = Self.refusal(Self.mutated { $0["id"] = "studio.blackpaw.github\n" })
    }

    @Test(arguments: ["1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "v1.2.3", "1.2.3-", "1.2.3-01", "1.2.3+", "latest", "", "１.２.３"])
    func badVersionsAreRefused(_ version: String) {
        let reason = Self.refusal(Self.mutated { $0["version"] = version })
        #expect(reason.contains("version"))
    }

    @Test(arguments: ["", "   "])
    func anEmptyNameIsRefused(_ name: String) {
        let reason = Self.refusal(Self.mutated { $0["name"] = name })
        #expect(reason.contains("name"))
    }

    @Test(arguments: ["dist/../../x.js", "..", "../main.js", "/etc/passwd", "/main.js", "~/main.js", "dist//main.js", "./main.js", "dist/./main.js", "dist/", "dist\\main.js", "a/..", "", "dist/ma\u{0}in.js", "dist/ma\nin.js", "../\u{0301}bundle.js", "dist/..\u{0301}/x.js", "dist/.\u{0301}/x.js", "a/\u{0301}/../b.js"])
    func mainEscapesAndMalformedPathsAreRefused(_ main: String) {
        let reason = Self.refusal(Self.mutated { $0["main"] = main })
        #expect(reason.contains("main"))
    }

    @Test(arguments: ["main.js", "dist/main.js", "build/out/plugin.bundle.js"])
    func relativeMainPathsAreAccepted(_ main: String) {
        guard case .valid = Self.validate(Self.mutated { $0["main"] = main }) else {
            Issue.record("\(main) should validate")
            return
        }
    }

    @Test(arguments: ["id", "name", "version", "apiVersion", "main"])
    func missingRequiredFieldsAreRefusedByName(_ key: String) {
        let reason = Self.refusal(Self.mutated { $0.removeValue(forKey: key) })
        #expect(reason.contains(key))
    }

    @Test func aWrongTypedFieldIsRefusedWithItsPath() {
        let reason = Self.refusal(Self.mutated { $0["name"] = 7 })
        #expect(reason.contains("name"))
    }

    @Test(arguments: [0, -1])
    func nonPositiveAPIVersionsAreRefused(_ version: Int) {
        let reason = Self.refusal(Self.mutated { $0["apiVersion"] = version })
        #expect(reason.contains("apiVersion"))
    }

    @Test func aFractionalAPIVersionIsRefused() {
        let reason = Self.refusal(Self.mutated { $0["apiVersion"] = 1.5 })
        #expect(reason.contains("apiVersion"))
    }

    // MARK: - Future API

    @Test func aFutureAPIVersionIsRefusedWithAReadableReason() {
        let reason = Self.refusal(Self.mutated { $0["apiVersion"] = LeoPluginAPI.supported + 1 })
        #expect(reason.contains("API version \(LeoPluginAPI.supported + 1)"))
        #expect(reason.contains("supports \(LeoPluginAPI.supported)"))
    }

    @Test func aFutureAPIVersionWinsOverSchemaErrorsItMayLegitimatelyHave() {
        let object = Self.mutated {
            $0["apiVersion"] = 2
            $0["somethingFromTheFuture"] = true
            $0["permissions"] = ["telepathy": true]
        }
        let reason = Self.refusal(object)
        #expect(reason.contains("API version 2"))
    }

    // MARK: - Strictness

    @Test func anUnknownTopLevelKeyIsRefused() {
        let reason = Self.refusal(Self.mutated { $0["homepage"] = "https://x.test" })
        #expect(reason.contains("homepage"))
    }

    @Test func anUnknownPermissionIsRefused() {
        let reason = Self.refusal(Self.mutated {
            $0["permissions"] = ["exec": true]
        })
        #expect(reason.contains("exec"))
        #expect(reason.contains("permission"))
    }

    @Test func anUnknownAgentVerbIsRefused() {
        let reason = Self.refusal(Self.mutated {
            $0["permissions"] = ["agents": ["read", "delete"]]
        })
        #expect(reason.contains("delete"))
    }

    @Test func anUnknownKeyInAContributionIsRefused() {
        let reason = Self.refusal(Self.mutated {
            $0["contributes"] = ["views": [["id": "pr", "title": "PR", "sfSymbol": "star", "icon": "x"]]]
        })
        #expect(reason.contains("icon"))
    }

    @Test func anUnknownContributionKindIsRefused() {
        let reason = Self.refusal(Self.mutated {
            $0["contributes"] = ["toolbars": []]
        })
        #expect(reason.contains("toolbars"))
    }

    @Test func malformedAndNonObjectJSONIsRefused() {
        for text in ["", "{", "[]", "null", "\"x\"", "{\"id\":"] {
            if case .valid = LeoPluginManifestValidator.validate(Data(text.utf8)) {
                Issue.record("\(text) should be refused")
            }
        }
    }

    @Test func anOversizedManifestIsRefusedBeforeParsing() {
        let padding = String(repeating: "a", count: LeoPluginManifestValidator.maxManifestBytes)
        let object = Self.mutated { $0["name"] = padding }
        let reason = Self.refusal(object)
        #expect(reason.contains("too large"))
    }

    // MARK: - Permissions shape

    @Test func duplicateAgentVerbsAreRefused() {
        let reason = Self.refusal(Self.mutated { $0["permissions"] = ["agents": ["read", "read"]] })
        #expect(reason.contains("read"))
    }

    @Test func secretsMustBeABoolean() {
        _ = Self.refusal(Self.mutated { $0["permissions"] = ["secrets": "yes"] })
    }

    // MARK: - Contributions

    @Test(arguments: ["Upper", "has space", "under_score", "", String(repeating: "a", count: 41), "é", "a/b", "ok\n"])
    func badContributionIDsAreRefused(_ id: String) {
        let reason = Self.refusal(Self.mutated {
            $0["contributes"] = ["sidebarSections": [["id": id, "title": "T"]]]
        })
        #expect(reason.contains("sidebarSections"))
    }

    @Test func aFortyCharacterContributionIDIsAccepted() {
        let id = String(repeating: "a", count: 40)
        guard case .valid = Self.validate(Self.mutated {
            $0["contributes"] = ["rowAccessories": [["id": id]]]
        }) else {
            Issue.record("expected valid")
            return
        }
    }

    @Test(arguments: ["views", "rowAccessories", "commands", "sidebarSections"])
    func duplicateContributionIDsWithinAKindAreRefused(_ kind: String) {
        let dup: [String: Any]
        switch kind {
        case "rowAccessories": dup = ["id": "same"]
        case "views": dup = ["id": "same", "title": "T", "sfSymbol": "star"]
        default: dup = ["id": "same", "title": "T"]
        }
        let reason = Self.refusal(Self.mutated { $0["contributes"] = [kind: [dup, dup]] })
        #expect(reason.contains(kind))
        #expect(reason.contains("same"))
    }

    @Test func theSameIDMayBeUsedAcrossKinds() {
        let object = Self.mutated {
            $0["contributes"] = [
                "views": [["id": "main", "title": "T", "sfSymbol": "star"]],
                "commands": [["id": "main", "title": "T"]],
                "rowAccessories": [["id": "main"]],
                "sidebarSections": [["id": "main", "title": "T"]],
            ]
        }
        guard case .valid = Self.validate(object) else {
            Issue.record("expected valid")
            return
        }
    }

    @Test func aViewWithoutASymbolOrWithABlankSymbolIsRefused() {
        let missing = Self.refusal(Self.mutated {
            $0["contributes"] = ["views": [["id": "pr", "title": "PR"]]]
        })
        #expect(missing.contains("sfSymbol"))
        let blank = Self.refusal(Self.mutated {
            $0["contributes"] = ["views": [["id": "pr", "title": "PR", "sfSymbol": "  "]]]
        })
        #expect(blank.contains("sfSymbol"))
    }

    @Test func aCommandSymbolMayBeAbsentButNotBlank() {
        let blank = Self.refusal(Self.mutated {
            $0["contributes"] = ["commands": [["id": "c", "title": "C", "sfSymbol": ""]]]
        })
        #expect(blank.contains("sfSymbol"))
    }

    @Test func blankTitlesAreRefused() {
        let entries: [String: [String: Any]] = [
            "views": ["id": "x", "title": " ", "sfSymbol": "star"],
            "commands": ["id": "x", "title": " "],
            "sidebarSections": ["id": "x", "title": " "],
        ]
        for (kind, entry) in entries {
            let reason = Self.refusal(Self.mutated { $0["contributes"] = [kind: [entry]] })
            #expect(reason.contains("title"), "\(kind)")
        }
    }
}

extension LeoPluginManifestTests {
    @Test(arguments: ["*", "*.com", "https://api.github.com", "api.github.com/x", "localhost", "127.0.0.1"])
    func badNetworkHostPatternsAreRefusedAtInstall(_ pattern: String) {
        let reason = Self.refusal(Self.mutated { $0["permissions"] = ["network": [pattern]] })
        #expect(reason.contains("network"))
        #expect(reason.contains(pattern))
    }

    @Test func duplicateNetworkHostsAreRefusedCaseInsensitively() {
        let reason = Self.refusal(Self.mutated { $0["permissions"] = ["network": ["a.test", "A.test."]] })
        #expect(reason.contains("network"))
    }
}

// MARK: - Panes and the usage verb

extension LeoPluginManifestTests {
    private static let statusPane: [String: Any] = ["id": "status", "title": "Status", "sfSymbol": "gauge"]

    @Test func aPaneDecodesWithOptionalSymbol() {
        let object = Self.mutated {
            $0["contributes"] = ["panes": [["id": "status", "title": "Status"]]]
        }
        guard case .valid(let manifest) = Self.validate(object) else {
            Issue.record("expected valid")
            return
        }
        #expect(manifest.contributes.panes == [LeoPluginPaneContribution(id: "status", title: "Status")])

        guard case .valid(let withSymbol) = Self.validate(Self.mutated { $0["contributes"] = ["panes": [Self.statusPane]] }) else {
            Issue.record("expected valid")
            return
        }
        #expect(withSymbol.contributes.panes.first?.sfSymbol == "gauge")
    }

    @Test func twoPanesAreRefused() {
        let reason = Self.refusal(Self.mutated {
            $0["contributes"] = ["panes": [Self.statusPane, ["id": "other", "title": "Other"]]]
        })
        #expect(reason.contains("panes"))
        #expect(reason.contains("one"))
    }

    @Test func anUnknownKeyInAPaneIsRefused() {
        let reason = Self.refusal(Self.mutated {
            $0["contributes"] = ["panes": [["id": "status", "title": "S", "icon": "x"]]]
        })
        #expect(reason.contains("icon"))
    }

    @Test(arguments: ["Upper", "has space", "", String(repeating: "a", count: 41)])
    func aBadPaneIDIsRefused(_ id: String) {
        let reason = Self.refusal(Self.mutated { $0["contributes"] = ["panes": [["id": id, "title": "S"]]] })
        #expect(reason.contains("panes"))
    }

    @Test func aBlankPaneTitleOrSymbolIsRefused() {
        let title = Self.refusal(Self.mutated { $0["contributes"] = ["panes": [["id": "s", "title": " "]]] })
        #expect(title.contains("title"))
        let symbol = Self.refusal(Self.mutated { $0["contributes"] = ["panes": [["id": "s", "title": "S", "sfSymbol": ""]]] })
        #expect(symbol.contains("sfSymbol"))
    }

    @Test func theUsageVerbIsAccepted() {
        guard case .valid(let manifest) = Self.validate(Self.mutated { $0["permissions"] = ["agents": ["read", "usage"]] }) else {
            Issue.record("expected valid")
            return
        }
        #expect(manifest.permissions.agents == [.read, .usage])
    }

    @Test func theUsageVerbWithoutReadIsRefused() {
        let reason = Self.refusal(Self.mutated { $0["permissions"] = ["agents": ["usage"]] })
        #expect(reason.contains("usage"))
        #expect(reason.contains("read"))
    }

    @Test func anUnknownVerbErrorListsUsage() {
        let reason = Self.refusal(Self.mutated { $0["permissions"] = ["agents": ["delete"]] })
        #expect(reason.contains("usage"))
    }
}
