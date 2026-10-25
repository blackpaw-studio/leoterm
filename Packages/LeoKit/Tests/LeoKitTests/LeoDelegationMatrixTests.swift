import Foundation
import Testing

@testable import LeoKit

struct LeoDelegationMatrixTests {
    static func document(
        roles: [LeoDelegationRole]? = nil, profiles: [LeoDelegationProfile]? = nil
    ) -> LeoDelegationDocument {
        LeoDelegationDocument(
            revision: "r1", activeProfile: "fast", hideNativeAgentsIsDefault: true,
            templates: [
                LeoDelegationTemplate(name: "coder", model: "opus"), LeoDelegationTemplate(name: "reviewer", model: "haiku"),
            ],
            roles: roles ?? [
                LeoDelegationRole(name: "coder", useFor: "writing code"), LeoDelegationRole(name: "qa", useFor: "tests"),
            ],
            profiles: profiles ?? [
                LeoDelegationProfile(name: "deep", roles: [
                    "coder": LeoDelegationCell(template: "coder", inheritedModel: "opus"),
                    "qa": LeoDelegationCell(template: "reviewer", model: "sonnet", effort: "high", inheritedModel: "haiku"),
                ]),
                LeoDelegationProfile(name: "fast", active: true, roles: [
                    "coder": LeoDelegationCell(template: "reviewer", inheritedModel: "haiku"),
                ]),
            ]
        )
    }

    @Test func rowsFollowTheRolesAndEachRowHasACellPerProfile() {
        let matrix = LeoDelegationMatrix(Self.document())

        #expect(matrix.rows.map(\.role.name) == ["coder", "qa"])
        #expect(matrix.profiles.map(\.name) == ["deep", "fast"])
        #expect(matrix.rows.allSatisfy { $0.cells.map(\.profile) == ["deep", "fast"] })
        #expect(matrix.rows[0].cells.map(\.isActive) == [false, true])
    }

    @Test func aCellIsLookedUpByProfileAndRoleAndIsNilWhenUnmapped() {
        let matrix = LeoDelegationMatrix(Self.document())

        #expect(matrix.cell(profile: "deep", role: "qa")?.template == "reviewer")
        #expect(matrix.cell(profile: "fast", role: "qa") == nil)
        #expect(matrix.cell(profile: "nope", role: "qa") == nil)
        #expect(matrix.rows[1].cells[1].value == nil)
    }

    @Test func theEffectiveModelIsTheOverrideElseTheTemplates() {
        let matrix = LeoDelegationMatrix(Self.document())

        #expect(matrix.cell(profile: "deep", role: "qa")?.effectiveModel == "sonnet")
        #expect(matrix.cell(profile: "deep", role: "coder")?.effectiveModel == "opus")
    }

    @Test func aRoleOnlyAProfileMentionsIsUndeclaredEvenWhenTheDaemonOmittedIt() {
        let document = Self.document(roles: [LeoDelegationRole(name: "coder", useFor: "x")])
        let matrix = LeoDelegationMatrix(document)

        #expect(matrix.rows.map(\.role.name) == ["coder", "qa"])
        #expect(matrix.undeclaredRoles == ["qa"])
        #expect(matrix.rows[1].role.declared == false)
    }

    @Test func aDaemonMarkedUndeclaredRoleIsReported() {
        let document = Self.document(roles: [LeoDelegationRole(name: "coder"), LeoDelegationRole(name: "qa", declared: false)])

        #expect(LeoDelegationMatrix(document).undeclaredRoles == ["qa"])
    }

    @Test func deletingARoleNamesTheProfilesThatRouteIt() {
        let matrix = LeoDelegationMatrix(Self.document())

        #expect(matrix.profilesRouting(role: "coder") == ["deep", "fast"])
        #expect(matrix.profilesRouting(role: "qa") == ["deep"])
        #expect(matrix.profilesRouting(role: "nope").isEmpty)
    }

    @Test func aProfilesUnmappedRolesAreTheDeclaredOnesItHasNoCellFor() {
        let matrix = LeoDelegationMatrix(Self.document())

        #expect(matrix.unmappedRoles(in: "fast") == ["qa"])
        #expect(matrix.unmappedRoles(in: "deep").isEmpty)
        #expect(matrix.routedRoleCount(in: "fast") == 1)
    }

    @Test func theActiveProfileIsFoundByItsFlag() {
        #expect(LeoDelegationMatrix(Self.document()).activeProfile?.name == "fast")
    }

    @Test func noProfilesMakesNoCellsAndNoActiveProfile() {
        let matrix = LeoDelegationMatrix(Self.document(profiles: []))

        #expect(matrix.rows.allSatisfy { $0.cells.isEmpty })
        #expect(matrix.activeProfile == nil)
    }
}
