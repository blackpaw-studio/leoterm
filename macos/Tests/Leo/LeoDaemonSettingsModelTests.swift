import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoDaemonSettingsModelTests {
    private struct Harness {
        let model: LeoDaemonSettingsModel
        let fake: LeoFakeConfigClient
    }

    private static func harness() async throws -> Harness {
        let fake = try LeoConfigGolden.client()
        let model = LeoDaemonSettingsModel(client: fake, revisions: LeoConfigRevisionTracker())
        await model.load()
        return Harness(model: model, fake: fake)
    }

    private static func hostChoices(_ model: LeoDaemonSettingsModel) -> [String]? {
        let control = model.client.sections.flatMap(\.rows).first { $0.path == "default_host" }?.control
        guard case .referencePicker(_, let names, _)? = control else { return nil }
        return names
    }

    // MARK: loading

    @Test func loadingReadsTheWebClientAndHostsForms() async throws {
        let harness = try await Self.harness()
        let model = harness.model

        #expect(model.web.phase == .loaded)
        #expect(model.client.phase == .loaded)
        #expect(model.hosts.phase == .loaded)
        #expect(model.web.title == "Web UI")
        #expect(model.client.title == "Remote client")
        #expect(model.hosts.title == "Remote hosts")
        #expect(model.hosts.items.map(\.name) == ["remote"])
        #expect(model.web.draft?.value(at: "port") == .int(8370))
    }

    @Test func theWebFormCarriesTheSchemasLockoutWarnings() async throws {
        let harness = try await Self.harness()
        let warnings = harness.model.web.sections.flatMap(\.rows).filter { !$0.field.warning.isEmpty }.map(\.path)

        #expect(warnings.contains("port"))
        #expect(warnings.contains("bind"))
        #expect(warnings.contains("allowed_hosts"))
    }

    @Test func theHostsAreAddedAndDeletedNotRenamed() async throws {
        let harness = try await Self.harness()

        #expect(harness.model.hosts.actions == [.add, .delete])
    }

    // MARK: web

    @Test func aWebSaveSetsTheServiceRestartAndKeepsTheOtherFormsUntouched() async throws {
        let harness = try await Self.harness()
        harness.model.web.set("port", .int(9000))
        await harness.model.web.save()

        #expect(harness.model.web.restartPrompt?.service == true)
        #expect(harness.model.client.restartPrompt == nil)
        #expect(!harness.model.hasUnsavedChanges)
        let updates = await harness.fake.calls.filter { if case .update = $0 { true } else { false } }
        #expect(updates.count == 1)
        guard case .update("web", nil, let patch, _)? = updates.first else {
            Issue.record("expected a web update")
            return
        }
        #expect(patch == ["port": .int(9000)])
    }

    @Test func aListEditOnTheWebFormReplaysOverTheOtherWritersListOnReload() async throws {
        let harness = try await Self.harness()
        harness.model.web.set("allowed_hosts", .list([.string("a.test")]))
        await harness.fake.externalChange("web", values: ["allowed_hosts": .list([.string("b.test")])])
        await harness.model.web.save()
        await harness.model.web.reloadAfterConflict()

        #expect(harness.model.web.draft?.value(at: "allowed_hosts") == .list([.string("b.test"), .string("a.test")]))
    }

    // MARK: hosts and default_host

    @Test func theDefaultHostChoicesAreTheHosts() async throws {
        let harness = try await Self.harness()

        #expect(Self.hostChoices(harness.model) == ["remote"])
    }

    @Test func theDefaultHostChoicesTrackAddedAndDeletedHosts() async throws {
        let harness = try await Self.harness()
        await harness.model.hosts.add(name: "staging")
        #expect(Self.hostChoices(harness.model) == ["remote", "staging"])

        harness.model.hosts.select("staging")
        harness.model.hosts.requestDelete()
        await harness.model.hosts.confirm(try #require(harness.model.hosts.confirmation))
        #expect(Self.hostChoices(harness.model) == ["remote"])
    }

    @Test func aHostAddedAfterTheFormLoadedCanBeChosenAsTheDefault() async throws {
        let harness = try await Self.harness()
        await harness.model.hosts.add(name: "staging")
        harness.model.client.set("default_host", .string("staging"))

        #expect(harness.model.client.canSave)
        await harness.model.client.save()
        #expect(harness.model.client.conflict == nil)
        #expect(try await harness.fake.document("client").values["default_host"] == .string("staging"))
    }

    @Test func aHostWriteDoesNotConflictAnOpenWebEdit() async throws {
        let harness = try await Self.harness()
        harness.model.web.set("port", .int(9000))
        await harness.model.hosts.add(name: "staging")
        await harness.model.web.save()

        #expect(harness.model.web.conflict == nil)
        #expect(!harness.model.web.isDirty)
    }

    @Test func deletingTheDefaultHostLeavesTheDefaultSetAndSaysSo() async throws {
        let harness = try await Self.harness()
        await harness.model.hosts.add(name: "staging")

        #expect(harness.model.deleteNote(forHost: "remote")?.contains("default host") == true)
        #expect(harness.model.deleteNote(forHost: "staging") == nil)

        harness.model.hosts.select("remote")
        harness.model.hosts.requestDelete()
        await harness.model.hosts.confirm(try #require(harness.model.hosts.confirmation))
        #expect(harness.model.client.draft?.value(at: "default_host") == .string("remote"))
        #expect(Self.hostChoices(harness.model) == ["staging"])
    }

    @Test func aHostIsEditedThroughItsOwnForm() async throws {
        let harness = try await Self.harness()
        harness.model.hosts.set("ssh_args", .list([.string("-p"), .string("2222")]))
        await harness.model.hosts.save()

        let stored = try await harness.fake.item("hosts", name: "remote").values["ssh_args"]
        #expect(stored == .list([.string("-p"), .string("2222")]))
        #expect(harness.model.hosts.restartPrompt == nil)
    }

    // MARK: unsaved changes and reload

    @Test func anyFormsEditsCountAsUnsavedAndDiscardDropsThemAll() async throws {
        let harness = try await Self.harness()
        let model = harness.model
        #expect(!model.hasUnsavedChanges)

        model.client.set("default_host", .string(""))
        #expect(model.hasUnsavedChanges)
        model.hosts.set("ssh", .string("me@other"))
        model.web.set("port", .int(9000))

        model.discardChanges()
        #expect(!model.hasUnsavedChanges)
    }

    @Test func reloadingWithANewClientKeepsEveryFormsEditsOverTheNewDocuments() async throws {
        let harness = try await Self.harness()
        harness.model.web.set("allowed_hosts", .list([.string("a.test")]))
        harness.model.hosts.set("ssh", .string("me@other"))
        let replacement = try LeoConfigGolden.client()
        await replacement.externalChange("web", values: ["allowed_hosts": .list([.string("b.test")]), "port": .int(9100)])
        await harness.model.reload(using: replacement)

        #expect(harness.model.web.draft?.value(at: "port") == .int(9100))
        #expect(harness.model.web.draft?.value(at: "allowed_hosts") == .list([.string("b.test"), .string("a.test")]))
        #expect(harness.model.hosts.draft?.value(at: "ssh") == .string("me@other"))
        #expect(harness.model.hasUnsavedChanges)
    }
}
