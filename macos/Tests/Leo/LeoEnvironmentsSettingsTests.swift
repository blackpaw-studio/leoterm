import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The Environments pane is the generic collection model on `environments`;
/// these pin what its one field, the `env` map, asks of it.
@MainActor struct LeoEnvironmentsSettingsTests {
    private static func harness(select: String? = nil) async throws -> (model: LeoConfigCollectionModel, fake: LeoFakeConfigClient) {
        let fake = try LeoConfigGolden.client(secretEnvironment: true)
        let model = LeoConfigCollectionModel(resource: "environments", client: fake, revisions: LeoConfigRevisionTracker())
        await model.load()
        if let select { model.select(select) }
        return (model, fake)
    }

    private static func updates(_ fake: LeoFakeConfigClient) async -> [LeoFakeConfigCall] {
        await fake.calls.filter { if case .update = $0 { true } else { false } }
    }

    @Test func theActionsAreAddRenameAndDelete() async throws {
        let (model, _) = try await Self.harness()

        #expect(model.title == "Environments")
        #expect(model.actions == [.add, .rename, .delete])
        #expect(model.items.map(\.name) == ["base", "work"])
    }

    @Test func aRemovedKeySendsOnlyThatEntryAsNull() async throws {
        let (model, fake) = try await Self.harness(select: "work")
        let env = try #require(model.draft?.value(at: "env"))
        model.set("env", env.replacingEnvEntries([:]))
        await model.save()

        #expect(await Self.updates(fake).count == 1)
        guard case .update(_, "work", let patch, _)? = await Self.updates(fake).first else {
            Issue.record("no update sent")
            return
        }
        #expect(patch == ["env": .object(["WORK_URL": .null])])
    }

    @Test func removingTheLastPlainKeyKeepsTheSecretOne() async throws {
        let (model, fake) = try await Self.harness(select: "work")
        let env = try #require(model.draft?.value(at: "env"))
        model.set("env", env.replacingEnvEntries([:]))
        await model.save()

        let stored = try await fake.item("environments", name: "work").values["env"]
        #expect(stored == .object(["WORK_TOKEN": .secret(isSet: true)]))
        #expect(model.errorMessage == nil)
    }

    @Test func removingTheOnlyKeyEmptiesTheMapWithoutClearingAnythingElse() async throws {
        let (model, fake) = try await Self.harness(select: "base")
        let env = try #require(model.draft?.value(at: "env"))
        model.set("env", env.replacingEnvEntries([:]))
        await model.save()

        #expect(model.errorMessage == nil)
        #expect(!model.isDirty)
        let stored = try await fake.item("environments", name: "base").values["env"] ?? .null
        #expect(stored.envEntries.isEmpty && stored.envSecrets.isEmpty)
        #expect(try await fake.item("environments", name: "work").values["env"]?.envSecrets == ["WORK_TOKEN": .set])
    }

    @Test func aSecretVariableNeverReachesTheFormAsText() async throws {
        let (model, _) = try await Self.harness(select: "work")
        let env = try #require(model.draft?.value(at: "env"))

        #expect(env.envEntries == ["WORK_URL": "http://work.local"])
        #expect(env.envSecrets == ["WORK_TOKEN": .set])
    }

    @Test func addingAKeyLeavesTheSecretAndTheOtherKeysOutOfThePatch() async throws {
        let (model, fake) = try await Self.harness(select: "work")
        let env = try #require(model.draft?.value(at: "env"))
        model.set("env", env.replacingEnvEntries(["WORK_URL": "http://work.local", "REGION": "eu"]))
        await model.save()

        guard case .update(_, _, let patch, _)? = await Self.updates(fake).first else {
            Issue.record("no update sent")
            return
        }
        #expect(patch == ["env": .object(["REGION": .string("eu")])])
    }

    @Test func clearingASecretDeletesJustThatEntry() async throws {
        let (model, fake) = try await Self.harness(select: "work")
        let env = try #require(model.draft?.value(at: "env"))
        model.set("env", env.settingEnvSecret("WORK_TOKEN", to: .secretClear))
        await model.save()

        let stored = try await fake.item("environments", name: "work").values["env"]
        #expect(stored == .map(["WORK_URL": "http://work.local"]))
    }

    @Test func renamingKeepsTheSelectionAndTheSecret() async throws {
        let (model, fake) = try await Self.harness(select: "work")
        await model.rename(to: "office")

        #expect(model.items.map(\.name) == ["base", "office"])
        #expect(model.selection == "office")
        #expect(model.draft?.document.name == "office")
        #expect(model.draft?.value(at: "env").envSecrets == ["WORK_TOKEN": .set])
        #expect(try await fake.item("environments", name: "office").values["env"] != nil)
    }

    @Test func aSaveRaisesTheAgentsRestartPrompt() async throws {
        let (model, _) = try await Self.harness()
        model.set("env", .map(["A": "1", "B": "2"]))
        await model.save()

        #expect(model.restartPrompt == LeoConfigRestartRequired(service: false, agents: true))
    }
}
