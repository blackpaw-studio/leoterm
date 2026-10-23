import Foundation
import Testing

@testable import LeoKit

struct LeoFakeConfigClientTests {
    private static func fake(supported: Bool = true) throws -> LeoFakeConfigClient {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        func items(_ name: String) throws -> [LeoConfigItem] {
            try LeoConfigFixtures.decode(LeoConfigCollection.self, name).items
        }
        func singleton(_ name: String) throws -> LeoConfigItem {
            try LeoConfigFixtures.decode(LeoConfigDocument.self, name).item
        }
        return LeoFakeConfigClient(
            schema: schema,
            singletons: ["defaults": try singleton("defaults"), "web": try singleton("web"), "client": try singleton("client")],
            collections: [
                "templates": try items("templates"), "tasks": try items("tasks"),
                "environments": try items("environments"), "hosts": try items("hosts"),
            ],
            version: LeoDaemonVersionInfo(version: "0.52.0", capabilities: supported ? [LeoConfigAPI.capability] : [])
        )
    }

    /// No registered daemon field is a secret yet, so the secret tests run on
    /// a synthetic `hosts` resource that has a write-only `token`.
    private static func secretFake() throws -> LeoFakeConfigClient {
        let schema = try JSONDecoder().decode(LeoConfigSchema.self, from: Data("""
        {"resources": [{"key": "hosts", "label": "Hosts", "kind": "collection", "section": "client_host", "actions": ["add", "delete"],
          "fields": [{"key": "token", "label": "Token", "type": "secret"}, {"key": "address", "label": "Address", "type": "string"}]}]}
        """.utf8))
        return LeoFakeConfigClient(
            schema: schema, collections: [
                "hosts": [
                    LeoConfigItem(name: "dionysus", values: ["token": .secret(isSet: true)]),
                    LeoConfigItem(name: "hestia", values: ["token": .secret(isSet: false)]),
                ],
            ],
            version: LeoDaemonVersionInfo(version: "0.52.0", capabilities: [LeoConfigAPI.capability])
        )
    }

    // MARK: revisions

    @Test func aStaleWriteIsAConflictAndWritesNothing() async throws {
        let fake = try Self.fake()
        let current = try await fake.document("web").revision

        await #expect(throws: LeoConfigError.conflict(currentRevision: current)) {
            _ = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: "sha256:stale")
        }
        let after = try await fake.document("web")
        #expect(after.values["port"] == .int(8370))
        #expect(after.revision == current)
    }

    @Test func aWriteBumpsTheRevisionAndTheOldOneThenConflicts() async throws {
        let fake = try Self.fake()
        let first = try await fake.document("web").revision
        let result = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: first)

        #expect(result.revision != first)
        #expect(try await fake.document("web").revision == result.revision)
        await #expect(throws: LeoConfigError.conflict(currentRevision: result.revision)) {
            _ = try await fake.update("web", name: nil, patch: ["port": .int(9001)], ifMatch: first)
        }
        _ = try await fake.update("web", name: nil, patch: ["port": .int(9001)], ifMatch: result.revision)
    }

    @Test func everyResourceSharesTheOneFileRevision() async throws {
        let fake = try Self.fake()
        let revision = try await fake.document("web").revision
        #expect(try await fake.collection("templates").revision == revision)

        let result = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: revision)
        #expect(try await fake.collection("templates").revision == result.revision)
        #expect(try await fake.document("defaults").revision == result.revision)
    }

    @Test func aMissingIfMatchIsRevisionRequired() async throws {
        let fake = try Self.fake()
        await #expect(throws: LeoConfigError.revisionRequired) {
            _ = try await fake.update("web", name: nil, patch: [:], ifMatch: "")
        }
    }

    @Test func anExternalChangeMakesTheHeldRevisionStale() async throws {
        let fake = try Self.fake()
        let held = try await fake.document("web").revision
        await fake.externalChange("web", values: ["bind": .string("0.0.0.0")])

        let fresh = try await fake.document("web")
        #expect(fresh.revision != held)
        #expect(fresh.values["bind"] == .string("0.0.0.0"))
        await #expect(throws: LeoConfigError.conflict(currentRevision: fresh.revision)) {
            _ = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: held)
        }
    }

    // MARK: update

    @Test func aPresentKeyReplacesNullClearsAndAnAbsentKeyStays() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("templates").revision
        _ = try await fake.update(
            "templates", name: "reviewer", patch: ["model": .string("gpt-6"), "max_turns": .null], ifMatch: revision
        )

        let reviewer = try await fake.item("templates", name: "reviewer")
        #expect(reviewer.values["model"] == .string("gpt-6"))
        #expect(reviewer.values["max_turns"] == nil)
        #expect(reviewer.values["harness"] == .string(""))
    }

    @Test func aSecretIsStoredAsSetOrNotSetNeverAsItsValue() async throws {
        let fake = try Self.secretFake()
        var revision = try await fake.collection("hosts").revision
        revision = try await fake.update("hosts", name: "hestia", patch: ["token": .secretReplace("s3cret")], ifMatch: revision).revision
        #expect(try await fake.item("hosts", name: "hestia").values["token"] == .secret(isSet: true))

        revision = try await fake.update("hosts", name: "dionysus", patch: ["token": .secretClear], ifMatch: revision).revision
        #expect(try await fake.item("hosts", name: "dionysus").values["token"] == .secret(isSet: false))
        #expect(try await fake.collection("hosts").items.allSatisfy { item in
            if case .secretReplace = item.values["token"] { return false }
            return item.values["token"] != .secretClear
        })
    }

    @Test func aSecretAddedWithAnItemIsNormalisedToo() async throws {
        let fake = try Self.secretFake()
        let revision = try await fake.collection("hosts").revision
        _ = try await fake.add("hosts", name: "new-host", values: ["token": .secretReplace("x"), "address": .string("h:1")], ifMatch: revision)

        #expect(try await fake.item("hosts", name: "new-host").values["token"] == .secret(isSet: true))
    }

    @Test func aKeySentAsNullIsDroppedNotStored() async throws {
        let fake = try Self.fake()
        let revision = try await fake.document("web").revision
        _ = try await fake.update("web", name: nil, patch: ["bind": .null], ifMatch: revision)

        #expect(try await fake.document("web").values["bind"] == nil)
    }

    @Test func aNestedObjectIsReplacedWhole() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("templates").revision
        _ = try await fake.update(
            "templates", name: "reviewer", patch: ["harness_options": .object(["profile": .string("p")])], ifMatch: revision
        )

        let options = try await fake.item("templates", name: "reviewer").values["harness_options"]?.objectValue
        #expect(options == ["profile": .string("p")])
    }

    // MARK: collections

    @Test func anAddedItemAppearsSortedAndIsReturned() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("templates").revision
        let result = try await fake.add("templates", name: "alpha", ifMatch: revision)

        #expect(result.item?.name == "alpha")
        #expect(result.item?.revision == result.revision)
        #expect(try await fake.collection("templates").items.map(\.name) == ["alpha", "coder", "reviewer"])
    }

    @Test func anAddCarriesItsExtraValues() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("tasks").revision
        _ = try await fake.add("tasks", name: "new-task", values: ["schedule": .string("0 1 * * *")], ifMatch: revision)

        #expect(try await fake.item("tasks", name: "new-task").values["schedule"] == .string("0 1 * * *"))
    }

    @Test func aTakenOrBadNameIsA422OnTheNameField() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("templates").revision

        await #expect(throws: LeoConfigError.invalid([LeoConfigFieldError(field: "name", message: "That name is already taken")])) {
            _ = try await fake.add("templates", name: "coder", ifMatch: revision)
        }
        await #expect(throws: LeoConfigError.invalid([LeoConfigFieldError(field: "new_name", message: "That name is already taken")])) {
            _ = try await fake.rename("templates", name: "reviewer", to: "coder", ifMatch: revision)
        }
        await #expect(throws: LeoConfigError.invalid([LeoConfigFieldError(field: "new_name", message: "Names can’t contain spaces or symbols other than . _ -")])) {
            _ = try await fake.duplicate("templates", name: "coder", as: "bad name", ifMatch: revision)
        }
        #expect(try await fake.collection("templates").revision == revision)
    }

    @Test func aRenameMovesTheItemAndRewritesReferencesToIt() async throws {
        let fake = try Self.fake()
        var revision = try await fake.collection("templates").revision
        revision = try await fake.update("tasks", name: "nightly", patch: ["template": .string("reviewer")], ifMatch: revision).revision
        _ = try await fake.rename("templates", name: "reviewer", to: "auditor", ifMatch: revision)

        #expect(try await fake.collection("templates").items.map(\.name) == ["auditor", "coder"])
        #expect(try await fake.item("tasks", name: "nightly").values["template"] == .string("auditor"))
        await #expect(throws: LeoDaemonError.self) { _ = try await fake.item("templates", name: "reviewer") }
    }

    @Test func aDuplicateIsADeepCopyUnderTheNewName() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("templates").revision
        let result = try await fake.duplicate("templates", name: "reviewer", as: "reviewer-2", ifMatch: revision)

        let original = try await fake.item("templates", name: "reviewer")
        let copy = try await fake.item("templates", name: "reviewer-2")
        #expect(copy.values == original.values)
        #expect(result.item?.name == "reviewer-2")
    }

    @Test func anActionTheSchemaDoesNotListIsRefused() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("tasks").revision
        await #expect(throws: LeoDaemonError.self) {
            _ = try await fake.duplicate("tasks", name: "nightly", as: "x", ifMatch: revision)
        }
        await #expect(throws: LeoDaemonError.self) {
            _ = try await fake.rename("tasks", name: "nightly", to: "x", ifMatch: revision)
        }
    }

    @Test func aDeleteRemovesTheItem() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("hosts").revision
        _ = try await fake.delete("hosts", name: "remote", ifMatch: revision)

        #expect(try await fake.collection("hosts").items.isEmpty)
    }

    @Test func aTemplateInUseCannotBeDeleted() async throws {
        let fake = try Self.fake()
        var revision = try await fake.collection("templates").revision
        revision = try await fake.update("tasks", name: "nightly", patch: ["template": .string("reviewer")], ifMatch: revision).revision

        await #expect(throws: LeoConfigError.invalid([LeoConfigFieldError(field: "", message: "reviewer is still used by tasks/nightly")])) {
            _ = try await fake.delete("templates", name: "reviewer", ifMatch: revision)
        }
        #expect(try await fake.collection("templates").items.count == 2)
    }

    @Test func anUnknownResourceOrItemIsNotFound() async throws {
        let fake = try Self.fake()
        let notFound = LeoDaemonError.daemon(code: "not_found", message: "No such config resource nope", matches: [])
        await #expect(throws: notFound) { _ = try await fake.document("nope") }
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: "No templates item ghost", matches: [])) {
            _ = try await fake.item("templates", name: "ghost")
        }
    }

    // MARK: scripting

    @Test func aScriptedFailureHitsTheNextWriteOnlyAndWritesNothing() async throws {
        let fake = try Self.fake()
        let revision = try await fake.document("web").revision
        let failure = LeoConfigError.invalid([LeoConfigFieldError(field: "port", message: "in use")])
        await fake.failNextWrite(with: failure)

        await #expect(throws: failure) {
            _ = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: revision)
        }
        #expect(try await fake.document("web").values["port"] == .int(8370))
        _ = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: revision)
        #expect(try await fake.document("web").values["port"] == .int(9000))
    }

    @Test func aScriptedReadFailureHitsTheNextReadOnly() async throws {
        let fake = try Self.fake()
        await fake.failNextRead(with: LeoDaemonError.timeout)

        await #expect(throws: LeoDaemonError.timeout) { _ = try await fake.document("web") }
        _ = try await fake.document("web")
    }

    @Test func aScriptedReplyHoldsUntilReleased() async throws {
        let fake = try Self.fake()
        await fake.holdReads()
        let reading = Task { try await fake.document("web") }
        await awaitCondition { await fake.heldReadCount == 1 }
        await fake.releaseReads()

        #expect(try await reading.value.values["port"] == .int(8370))
    }

    // MARK: restart and version

    @Test func restartRequiredFollowsEachResourcesScopeAndSticks() async throws {
        let fake = try Self.fake()
        var revision = try await fake.document("web").revision

        let task = try await fake.update("tasks", name: "heartbeat", patch: ["enabled": .bool(true)], ifMatch: revision)
        #expect(task.restartRequired == LeoConfigRestartRequired(service: false, agents: false))
        revision = task.revision

        let template = try await fake.update("templates", name: "coder", patch: ["model": .string("m")], ifMatch: revision)
        #expect(template.restartRequired == LeoConfigRestartRequired(service: false, agents: true))
        revision = template.revision

        let web = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: revision)
        #expect(web.restartRequired == LeoConfigRestartRequired(service: true, agents: true))

        await fake.clearRestartRequired()
        let again = try await fake.update("tasks", name: "heartbeat", patch: ["enabled": .bool(false)], ifMatch: web.revision)
        #expect(!again.restartRequired.isNeeded)
    }

    @Test func aDaemonWithoutTheCapabilityHasNoSchema() async throws {
        let fake = try Self.fake(supported: false)

        await #expect(throws: LeoConfigError.unsupported) { _ = try await fake.schema() }
        #expect(try await fake.versionInfo().capabilities.isEmpty)
    }

    @Test func versionAndSchemaAreServed() async throws {
        let fake = try Self.fake()

        #expect(try await fake.versionInfo().version == "0.52.0")
        #expect(try await fake.schema().resources.count == 8)
    }

    @Test func everyCallIsRecordedInOrder() async throws {
        let fake = try Self.fake()
        let revision = try await fake.document("web").revision
        _ = try await fake.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: revision)
        _ = try await fake.item("templates", name: "coder")

        #expect(await fake.calls == [
            .document("web"),
            .update(resource: "web", name: nil, patch: ["port": .int(9000)], ifMatch: revision),
            .item(resource: "templates", name: "coder"),
        ])
    }

    @Test func aFailedWriteIsStillRecorded() async throws {
        let fake = try Self.fake()
        _ = try? await fake.update("web", name: nil, patch: [:], ifMatch: "stale")

        #expect(await fake.calls == [.update(resource: "web", name: nil, patch: [:], ifMatch: "stale")])
    }
}
