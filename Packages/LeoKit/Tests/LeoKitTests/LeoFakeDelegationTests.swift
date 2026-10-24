import Foundation
import Testing

@testable import LeoKit

struct LeoFakeDelegationTests {
    private static func fake(_ document: LeoDelegationDocument? = LeoDelegationMatrixTests.document()) throws -> LeoFakeConfigClient {
        LeoFakeConfigClient(schema: try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema"), delegation: document)
    }

    private static func revision(_ fake: LeoFakeConfigClient) async throws -> String {
        try await fake.delegation().revision
    }

    // MARK: reads

    @Test func readingAnUnconfiguredDaemonSaysSoAndWritesAre404() async throws {
        let fake = try Self.fake(nil)
        let document = try await fake.delegation()

        #expect(!document.configured)
        do {
            _ = try await fake.setDelegationEnabled(true, ifMatch: document.revision)
            Issue.record("Expected a 404")
        } catch LeoDaemonError.daemon(let code, _, _) {
            #expect(code == "delegation_not_configured")
        }
    }

    @Test func theDocumentComesBackAsSeededWithInheritedModelsFilledIn() async throws {
        let document = try await Self.fake().delegation()

        #expect(document.activeProfile == "fast")
        #expect(document.profiles[1].roles["coder"]?.inheritedModel == "haiku")
        #expect(document.roles.map(\.name) == ["coder", "qa"])
        #expect(document.hideNativeAgentsIsDefault)
        #expect(!document.hideNativeAgents.isEmpty)
    }

    // MARK: cells

    @Test func aCellWriteStoresTheCellBumpsTheRevisionAndRaisesTheRestartFlags() async throws {
        let fake = try Self.fake()
        let before = try await Self.revision(fake)

        let result = try await fake.setDelegationCell(
            profile: "fast", role: "qa", target: LeoDelegationTarget(template: "coder", effort: "high"), ifMatch: before
        )

        #expect(result.revision != before)
        #expect(result.restartRequired.agents && result.restartRequired.service)
        let cell = try #require(result.item?.profiles[1].roles["qa"])
        #expect(cell.template == "coder" && cell.effort == "high" && cell.inheritedModel == "opus")
        #expect(try await fake.delegation().revision == result.revision)
    }

    @Test func anEmptyTemplateDeletesTheCell() async throws {
        let fake = try Self.fake()

        let result = try await fake.setDelegationCell(profile: "deep", role: "qa", target: LeoDelegationTarget(), ifMatch: try await Self.revision(fake))

        #expect(result.item?.profiles[0].roles["qa"] == nil)
    }

    @Test func anUnknownTemplateIs422OnTemplateAndABadEffortOnEffort() async throws {
        let fake = try Self.fake()
        let revision = try await Self.revision(fake)

        await #expect(throws: LeoConfigError.self) {
            _ = try await fake.setDelegationCell(profile: "fast", role: "qa", target: LeoDelegationTarget(template: "ghost"), ifMatch: revision)
        }
        do {
            _ = try await fake.setDelegationCell(
                profile: "fast", role: "qa", target: LeoDelegationTarget(template: "coder", effort: "ludicrous"), ifMatch: revision
            )
            Issue.record("Expected a 422")
        } catch LeoConfigError.invalid(let errors) {
            #expect(errors.map(\.field) == ["effort"])
        }
        #expect(try await Self.revision(fake) == revision)
    }

    @Test func aStaleWriteIsAConflictAndAMissingRevisionIs428() async throws {
        let fake = try Self.fake()
        let stale = try await Self.revision(fake)
        await fake.externalChange("web", values: ["port": .int(1)])

        do {
            _ = try await fake.setDelegationEnabled(false, ifMatch: stale)
            Issue.record("Expected a 409")
        } catch LeoConfigError.conflict(let current) {
            #expect(current == (try await Self.revision(fake)))
        }
        await #expect(throws: LeoConfigError.revisionRequired) { _ = try await fake.setDelegationEnabled(false, ifMatch: "") }
        #expect(try await fake.delegation().enabled)
    }

    // MARK: single-key writes

    @Test func useForEnabledActiveAndHiddenAgentsEachChangeOneKey() async throws {
        let fake = try Self.fake()

        _ = try await fake.setRoleUseFor(role: "qa", useFor: "run tests", ifMatch: try await Self.revision(fake))
        _ = try await fake.setDelegationEnabled(false, ifMatch: try await Self.revision(fake))
        _ = try await fake.setActiveProfile("deep", ifMatch: try await Self.revision(fake))
        _ = try await fake.setHiddenAgents(["Explore"], ifMatch: try await Self.revision(fake))

        let document = try await fake.delegation()
        #expect(document.roles.first { $0.name == "qa" }?.useFor == "run tests")
        #expect(!document.enabled)
        #expect(document.activeProfile == "deep")
        #expect(document.profiles.map(\.active) == [true, false])
        #expect(document.hideNativeAgents == ["Explore"])
        #expect(!document.hideNativeAgentsIsDefault)
    }

    @Test func anEmptyHideListHidesNoneAndIsNoLongerTheDefault() async throws {
        let fake = try Self.fake()

        let result = try await fake.setHiddenAgents([], ifMatch: try await Self.revision(fake))

        #expect(result.item?.hideNativeAgents == [])
        #expect(result.item?.hideNativeAgentsIsDefault == false)
    }

    @Test func activatingAnUnknownProfileIs404() async throws {
        let fake = try Self.fake()
        await #expect(throws: LeoDaemonError.self) { _ = try await fake.setActiveProfile("ghost", ifMatch: try await Self.revision(fake)) }
    }

    // MARK: roles

    @Test func addingARoleRoutesItToTheTemplateInTheActiveProfileOnly() async throws {
        let fake = try Self.fake()

        let result = try await fake.addDelegationRole(name: "docs", template: "reviewer", ifMatch: try await Self.revision(fake))

        let document = try #require(result.item)
        #expect(document.roles.map(\.name) == ["coder", "docs", "qa"])
        #expect(document.profiles[1].roles["docs"]?.template == "reviewer")
        #expect(document.profiles[0].roles["docs"] == nil)
    }

    @Test func addingARoleChecksTheNameAndTheTemplate() async throws {
        let fake = try Self.fake()
        let revision = try await Self.revision(fake)

        await #expect(throws: LeoConfigError.self) { _ = try await fake.addDelegationRole(name: "coder", template: "coder", ifMatch: revision) }
        await #expect(throws: LeoConfigError.self) { _ = try await fake.addDelegationRole(name: "has space", template: "coder", ifMatch: revision) }
        await #expect(throws: LeoConfigError.self) { _ = try await fake.addDelegationRole(name: "new", template: "ghost", ifMatch: revision) }
    }

    @Test func renamingARoleMovesItsCellsAndDescription() async throws {
        let fake = try Self.fake()

        let result = try await fake.renameDelegationRole("qa", to: "tester", ifMatch: try await Self.revision(fake))

        let document = try #require(result.item)
        #expect(document.roles.map(\.name) == ["coder", "tester"])
        #expect(document.roles.last?.useFor == "tests")
        #expect(document.profiles[0].roles["tester"]?.template == "reviewer")
        #expect(document.profiles[0].roles["qa"] == nil)
    }

    @Test func deletingARoleRemovesItFromEveryProfile() async throws {
        let fake = try Self.fake()

        let result = try await fake.deleteDelegationRole("qa", ifMatch: try await Self.revision(fake))

        #expect(result.item?.roles.map(\.name) == ["coder"])
        #expect(result.item?.profiles.allSatisfy { $0.roles["qa"] == nil } == true)
    }

    @Test func theLastDeclaredRoleCantBeDeleted() async throws {
        let fake = try Self.fake(LeoDelegationMatrixTests.document(roles: [LeoDelegationRole(name: "coder")]))

        await #expect(throws: LeoConfigError.self) { _ = try await fake.deleteDelegationRole("coder", ifMatch: try await Self.revision(fake)) }
    }

    // MARK: profiles

    @Test func profilesAreAddedRenamedDuplicatedAndDeleted() async throws {
        let fake = try Self.fake()

        _ = try await fake.addDelegationProfile(name: "cheap", ifMatch: try await Self.revision(fake))
        _ = try await fake.duplicateDelegationProfile("deep", as: "deep2", ifMatch: try await Self.revision(fake))
        _ = try await fake.renameDelegationProfile("cheap", to: "thrifty", ifMatch: try await Self.revision(fake))
        let result = try await fake.deleteDelegationProfile("deep", ifMatch: try await Self.revision(fake))

        let document = try #require(result.item)
        #expect(document.profiles.map(\.name) == ["deep2", "fast", "thrifty"])
        #expect(document.profiles[0].roles["qa"]?.template == "reviewer")
        #expect(document.profiles[2].roles.isEmpty)
    }

    @Test func renamingTheActiveProfileKeepsItActive() async throws {
        let fake = try Self.fake()

        let result = try await fake.renameDelegationProfile("fast", to: "quick", ifMatch: try await Self.revision(fake))

        #expect(result.item?.activeProfile == "quick")
        #expect(result.item?.profiles.first { $0.name == "quick" }?.active == true)
    }

    @Test func theActiveProfileCantBeDeletedAndANameCantBeTakenTwice() async throws {
        let fake = try Self.fake()
        let revision = try await Self.revision(fake)

        await #expect(throws: LeoConfigError.self) { _ = try await fake.deleteDelegationProfile("fast", ifMatch: revision) }
        await #expect(throws: LeoConfigError.self) { _ = try await fake.duplicateDelegationProfile("deep", as: "fast", ifMatch: revision) }
        await #expect(throws: LeoConfigError.self) { _ = try await fake.addDelegationProfile(name: "deep", ifMatch: revision) }
    }

    // MARK: preview

    @Test func aPreviewListsAddedRemovedAndChangedRolesAndTheMissingOnes() async throws {
        let fake = try Self.fake()

        let toDeep = try await fake.delegationPreview(profile: "deep")
        #expect(toDeep.changes.map(\.role) == ["coder", "qa"])
        #expect(toDeep.changes.map(\.kind) == [.changed, .added])
        #expect(toDeep.changes[0].before.template == "reviewer" && toDeep.changes[0].after.template == "coder")
        #expect(toDeep.missing.isEmpty)

        _ = try await fake.setActiveProfile("deep", ifMatch: try await Self.revision(fake))
        let toFast = try await fake.delegationPreview(profile: "fast")
        #expect(toFast.changes.map(\.kind) == [.changed, .removed])
        #expect(toFast.missing == ["qa"])
    }

    @Test func previewingAnUnknownProfileIs404() async throws {
        let fake = try Self.fake()
        await #expect(throws: LeoDaemonError.self) { _ = try await fake.delegationPreview(profile: "ghost") }
    }

    // MARK: scripting

    @Test func everyDelegationCallIsRecorded() async throws {
        let fake = try Self.fake()
        let revision = try await Self.revision(fake)

        _ = try await fake.setDelegationCell(profile: "fast", role: "qa", target: LeoDelegationTarget(template: "coder"), ifMatch: revision)

        #expect(await fake.calls == [
            .delegation,
            .delegationWrite(.cell(profile: "fast", role: "qa", target: LeoDelegationTarget(template: "coder")), ifMatch: revision),
        ])
    }

    @Test func anExternalChangeToACellBumpsTheRevision() async throws {
        let fake = try Self.fake()
        let before = try await Self.revision(fake)

        await fake.externalDelegationChange(profile: "fast", role: "coder", target: LeoDelegationTarget(template: "coder", effort: "low"))

        let document = try await fake.delegation()
        #expect(document.revision != before)
        #expect(document.profiles[1].roles["coder"]?.effort == "low")
    }
}
