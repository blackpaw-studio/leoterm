import Foundation
import Testing

@testable import LeoKit

struct LeoDelegationModelsTests {
    @Test func theGoldenDocumentDecodes() throws {
        let document = try LeoConfigFixtures.decode(LeoDelegationDocument.self, "delegation")

        #expect(document.revision.hasPrefix("sha256:"))
        #expect(document.configured)
        #expect(document.enabled)
        #expect(document.activeProfile == "fast")
        #expect(document.hideNativeAgents.count == 6)
        #expect(document.hideNativeAgentsIsDefault)
        #expect(document.templates == [LeoDelegationTemplate(name: "coder", model: "opus"), LeoDelegationTemplate(name: "reviewer", model: "haiku")])
        #expect(document.roles == [LeoDelegationRole(name: "coder", useFor: "writing code", declared: true)])
        #expect(document.profiles.map(\.name) == ["deep", "fast"])
        #expect(document.profiles.map(\.active) == [false, true])
        #expect(document.profiles[1].roles["coder"] == LeoDelegationCell(template: "reviewer", model: "", effort: "", inheritedModel: "haiku"))
        #expect(document.warnings.isEmpty)
        #expect(document.recentConsults.isEmpty)
    }

    @Test func theGoldenWriteReplyCarriesTheRefreshedDocument() throws {
        let result = try LeoConfigFixtures.decode(LeoDelegationWriteResult.self, "delegation_cell")

        #expect(result.revision == result.item?.revision)
        #expect(result.restartRequired.agents && result.restartRequired.service)
        #expect(result.item?.profiles[1].roles["coder"]?.effort == "high")
    }

    @Test func thePreviewDecodes() throws {
        let preview = try LeoConfigFixtures.decode(LeoDelegationPreview.self, "delegation_preview")

        #expect(preview.profile == "deep")
        #expect(preview.missing.isEmpty)
        #expect(preview.changes == [
            LeoDelegationPreview.Change(
                role: "coder", kind: .changed,
                before: LeoDelegationTarget(template: "reviewer"), after: LeoDelegationTarget(template: "coder")
            ),
        ])
    }

    @Test func anUnconfiguredBlockDecodesToAnEmptyDocument() throws {
        let body = """
        {"ok": true, "data": {"revision": "sha256:r", "configured": false, "enabled": false, "active_profile": "",
        "hide_native_agents": [], "hide_native_agents_is_default": false, "templates": [], "roles": [], "profiles": [],
        "warnings": [], "recent_consults": []}}
        """
        let document = try LeoDaemonEnvelope<LeoDelegationDocument>.decode(Data(body.utf8)).value()

        #expect(!document.configured)
        #expect(document.profiles.isEmpty && document.roles.isEmpty)
    }

    @Test func aPreviewKindWeDontKnowIsKeptAsChanged() throws {
        let body = """
        {"ok": true, "data": {"profile": "p", "missing": ["x"], "changes": [
        {"role": "r", "kind": "moved", "before": {"template": "a"}, "after": {"template": "b"}}]}}
        """
        let preview = try LeoDaemonEnvelope<LeoDelegationPreview>.decode(Data(body.utf8)).value()

        #expect(preview.changes.first?.kind == .changed)
        #expect(preview.missing == ["x"])
    }

    @Test func aRecentConsultKeepsWhatTheTableShowsAndIgnoresTheRest() throws {
        let body = """
        {"ok": true, "data": {"revision": "r", "configured": true, "enabled": true, "active_profile": "p",
        "hide_native_agents": [], "hide_native_agents_is_default": false, "templates": [], "roles": [], "profiles": [],
        "warnings": ["role \\"x\\" has no template"], "recent_consults": [
        {"id": "d-1", "role": "coder", "profile": "fast", "template": "coder", "model": "", "effort": "high",
         "status": "done", "prompt": "…", "started_at": "2026-10-23T15:00:00Z", "active_seconds": 4.5},
        {"id": "d-2", "role": "reviewer", "status": "running", "started_at": "2026-10-23T15:05:00Z"}]}}
        """
        let document = try LeoDaemonEnvelope<LeoDelegationDocument>.decode(Data(body.utf8)).value()

        #expect(document.warnings == ["role \"x\" has no template"])
        #expect(document.recentConsults.map(\.id) == ["d-1", "d-2"])
        #expect(document.recentConsults[0].role == "coder")
        #expect(document.recentConsults[0].effort == "high")
        #expect(document.recentConsults[0].status == "done")
        #expect(document.recentConsults[0].startedAt != nil)
        #expect(document.recentConsults[1].template == "")
    }
}
