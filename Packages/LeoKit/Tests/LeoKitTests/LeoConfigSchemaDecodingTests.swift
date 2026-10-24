import Foundation
import Testing

@testable import LeoKit

struct LeoConfigSchemaDecodingTests {
    private func decodeSchema(_ json: String) throws -> LeoConfigSchema {
        try JSONDecoder().decode(LeoConfigSchema.self, from: Data(json.utf8))
    }

    @Test(arguments: LeoConfigFixtures.names)
    func everyFixtureIsAWellFormedEnvelope(name: String) throws {
        let object = try #require(try JSONSerialization.jsonObject(with: try LeoConfigFixtures.data(name)) as? [String: Any])
        #expect(object["ok"] is Bool)
    }

    @Test func theSchemaFixtureDecodes() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")

        #expect(schema.schemaVersion == 1)
        #expect(schema.namePattern == "^[A-Za-z0-9._-]+$")
        #expect(schema.resources.map(\.key) == ["defaults", "templates", "tasks", "environments", "web", "client", "hosts", "delegation"])
        #expect(Set(schema.harnesses.keys) == ["claude", "codex", "opencode"])
        #expect(schema.resource("delegation")?.kind == .other("bespoke"))
    }

    @Test func aResourceCarriesItsKindActionsAndRestartScope() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let templates = try #require(schema.resource("templates"))

        #expect(templates.kind == .collection)
        #expect(templates.section == "template")
        #expect(templates.actions == [.add, .rename, .duplicate, .delete])
        #expect(templates.harnessOptions)
        #expect(templates.restart == .agents)
        #expect(templates.subsections.map(\.key) == ["permissions", "push"])
        #expect(schema.resource("web")?.restart == .service)
        #expect(schema.resource("tasks")?.restart == LeoConfigRestartScope.none)
        #expect(schema.resource("web")?.kind == .singleton)
        #expect(schema.resource("nope") == nil)
    }

    @Test func aFieldCarriesItsTypeExtrasAndConstraints() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let templates = try #require(schema.resource("templates"))

        let maxTurns = try #require(templates.field("max_turns"))
        #expect(maxTurns.type == .int)
        #expect(maxTurns.constraints.min == 0)
        #expect(maxTurns.constraints.max == nil)
        #expect(maxTurns.defaultValue == .null)

        let workspace = try #require(templates.field("workspace"))
        #expect(!workspace.constraints.required)
        #expect(workspace.group == "General")
        #expect(!workspace.advanced)

        #expect(templates.field("idle_suspend_after")?.type == .duration)
        #expect(templates.field("idle_suspend_after")?.advanced == true)
        #expect(templates.field("env")?.type == .map)
        #expect(templates.field("env")?.advanced == true)
        #expect(schema.resource("web")?.field("port")?.defaultValue == .int(8370))
        #expect(schema.resource("web")?.field("port")?.warning.contains("lock you out") == true)

        let harness = try #require(templates.field("harness"))
        #expect(harness.type == .enum)
        #expect(harness.options.map(\.value) == ["", "claude", "codex", "opencode"])
        #expect(harness.options.first?.label == "inherit")
    }

    @Test func aMultilineOrNullableFieldDecodes() throws {
        // The registered fields have neither flag yet, so the field is synthetic.
        let schema = try decodeSchema("""
        {"resources": [{"key": "r", "label": "R", "fields": [
          {"key": "prompt", "label": "Prompt", "type": "string", "multiline": true},
          {"key": "limit", "label": "Limit", "type": "int", "nullable": true}]}]}
        """)
        #expect(schema.resource("r")?.field("prompt")?.multiline == true)
        #expect(schema.resource("r")?.field("limit")?.nullable == true)
    }

    @Test func modelHintsAreKeyedByHarness() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let model = try #require(schema.resource("templates")?.field("model"))

        #expect(model.hintsByHarness["claude"]?.suggestions.contains("opus") == true)
        #expect(model.hintsByHarness["codex"]?.placeholder == "e.g. gpt-5.3-codex")
    }

    @Test func cronAndReferenceFieldsDecode() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let tasks = try #require(schema.resource("tasks"))

        #expect(tasks.field("schedule")?.format == "cron")
        #expect(tasks.field("schedule")?.constraints.required == true)
        #expect(tasks.field("template")?.type == .reference)
        #expect(tasks.field("template")?.references == "templates")
        #expect(tasks.field("template")?.emptyLabel == "none")
    }

    @Test func secretAndPatternFieldsDecode() throws {
        // No registered field is a secret or has a pattern yet.
        let schema = try decodeSchema("""
        {"resources": [{"key": "hosts", "label": "H", "fields": [
          {"key": "token", "label": "Token", "type": "secret"},
          {"key": "address", "label": "Address", "type": "string", "constraints": {"pattern": "^[^\\\\s]+$"}}]}]}
        """)
        #expect(schema.resource("hosts")?.field("token")?.type == .secret)
        #expect(schema.resource("hosts")?.field("address")?.constraints.pattern == "^[^\\s]+$")
    }

    @Test func harnessSchemasDecodeIncludingYAMLOptions() throws {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")

        #expect(schema.harnesses["claude"]?.fields.first?.key == "permission_mode")
        #expect(schema.harnesses["claude"]?.fields.contains { $0.key == "allowed_tools" && $0.type == .list } == true)
        #expect(schema.harnesses["opencode"]?.fields.first?.type == .yaml)
        #expect(schema.harnesses["codex"]?.fields.first?.options.map(\.value) == ["read-only", "workspace-write", "danger-full-access", "approve-for-me"])
        #expect(schema.harnesses["claude"]?.fields.allSatisfy(\.nullable) == true)
    }

    @Test func anUnknownTypeDecodesAsUnknownAndDoesNotFail() throws {
        let schema = try decodeSchema("""
        {"schema_version": 1, "name_pattern": "", "harnesses": {}, "resources": [
          {"key": "web", "label": "Web", "kind": "singleton", "section": "web", "actions": [], "fields": [
            {"key": "tint", "label": "Tint", "type": "color"}]}]}
        """)
        let field = try #require(schema.resource("web")?.field("tint"))

        #expect(field.type == .unknown("color"))
        #expect(field.label == "Tint")
    }

    @Test func unknownKeysKindsActionsAndRestartScopesAreIgnoredOrKept() throws {
        let schema = try decodeSchema("""
        {"schema_version": 7, "future": {"x": 1}, "resources": [
          {"key": "widgets", "label": "Widgets", "kind": "tree", "section": "widget", "restart": "reboot",
           "actions": ["add", "teleport"], "sparkles": true,
           "fields": [{"key": "a", "label": "A", "type": "string", "sparkles": [1, 2]}]}]}
        """)
        let widgets = try #require(schema.resource("widgets"))

        #expect(widgets.kind == .other("tree"))
        #expect(widgets.restart == .other("reboot"))
        #expect(widgets.actions == [.add])
        #expect(widgets.field("a")?.type == .string)
    }

    @Test func missingOptionalPartsTakeDefaults() throws {
        let schema = try decodeSchema(#"{"resources": [{"key": "r", "label": "R", "fields": [{"key": "a", "type": "bool"}]}]}"#)
        let field = try #require(schema.resource("r")?.field("a"))

        #expect(schema.schemaVersion == 1)
        #expect(schema.resource("r")?.subsections.isEmpty == true)
        #expect(field.label == "a")
        #expect(field.options.isEmpty)
        #expect(!field.constraints.required)
        #expect(field.defaultValue == .null)
    }

    @Test func documentsDecodeValuesInheritedAndHarness() throws {
        let document = try LeoConfigFixtures.decode(LeoConfigDocument.self, "template_coder")

        #expect(document.revision.hasPrefix("sha256:"))
        #expect(document.name == "coder")
        #expect(document.effectiveHarness == "claude")
        #expect(document.values["max_turns"] == .null)
        #expect(document.values["model"] == .string("opus"))
        #expect(document.values["environments"] == .list([]))
        #expect(document.values["env"] == .map([:]))
        #expect(document.values["harness_options"]?.objectValue?["permission_mode"] == .string("plan"))
        #expect(document.values["push"]?.objectValue?["chat"] == .null)
        #expect(document.values["permissions"]?.objectValue?["can_spawn"] == .list([.string("reviewer")]))
    }

    @Test func aTaskCarriesTheDefaultsItInherits() throws {
        let heartbeat = try #require(try LeoConfigFixtures.decode(LeoConfigCollection.self, "tasks").items.first { $0.name == "heartbeat" })
        #expect(heartbeat.inherited["model"] == .string("sonnet"))
        #expect(heartbeat.effectiveHarness == "claude")
    }

    @Test func singletonDocumentsHaveNoName() throws {
        for name in ["defaults", "web", "client"] {
            let document = try LeoConfigFixtures.decode(LeoConfigDocument.self, name)
            #expect(document.name == nil)
            #expect(document.revision.hasPrefix("sha256:"))
        }
        #expect(try LeoConfigFixtures.decode(LeoConfigDocument.self, "web").values["port"] == .int(8370))
    }

    @Test(arguments: ["templates", "tasks", "environments", "hosts"])
    func collectionsDecodeItemsInOrder(name: String) throws {
        let collection = try LeoConfigFixtures.decode(LeoConfigCollection.self, name)

        #expect(collection.revision.hasPrefix("sha256:"))
        #expect(!collection.items.isEmpty)
        #expect(collection.items.map(\.name) == collection.items.map(\.name).sorted())
    }

    @Test func aSecretReadsAsSetOrNotSet() throws {
        // No registered collection has a secret yet; the wire form is `{"set": bool}`.
        let items = try JSONDecoder().decode(LeoConfigCollection.self, from: Data("""
        {"revision": "sha256:1", "items": [
          {"name": "a", "values": {"token": {"set": true}}}, {"name": "b", "values": {"token": {"set": false}}}]}
        """.utf8)).items

        #expect(items.first?.values["token"] == .secret(isSet: true))
        #expect(items.last?.values["token"] == .secret(isSet: false))
    }

    @Test func aWriteResultCarriesTheRevisionRestartFlagsAndWarning() throws {
        let result = try LeoConfigFixtures.decode(LeoConfigWriteResult.self, "write_result")

        #expect(result.revision == "sha256:bb22")
        #expect(result.restartRequired == LeoConfigRestartRequired(service: false, agents: true))
        #expect(result.warning == "saved, but reload failed: boom")
        #expect(result.item?.name == "coder")
    }

    @Test func aWriteResultWithoutOptionalPartsDecodes() throws {
        let result = try JSONDecoder().decode(LeoConfigWriteResult.self, from: Data(#"{"revision":"sha256:1"}"#.utf8))
        #expect(result.restartRequired == LeoConfigRestartRequired(service: false, agents: false))
        #expect(result.warning == nil)
        #expect(result.item == nil)
    }
}
