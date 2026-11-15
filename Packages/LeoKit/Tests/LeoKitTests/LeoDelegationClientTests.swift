import Foundation
import Testing

@testable import LeoKit

struct LeoDelegationClientTests {
    static let prefixes = ["", "/api/v1"]

    private static func client(prefix: String, _ transport: ConfigRecordingTransport) -> LeoConfigHTTPClient {
        LeoConfigHTTPClient(prefix: prefix, transport: transport)
    }

    private static func json(_ request: LeoHTTPRequest) throws -> NSDictionary {
        let body = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }

    @Test(arguments: prefixes)
    func readsUseGetWithoutIfMatch(prefix: String) async throws {
        let transport = ConfigRecordingTransport(fixtures: ["delegation", "delegation_preview"])
        let client = Self.client(prefix: prefix, transport)

        let document = try await client.delegation()
        let preview = try await client.delegationPreview(profile: "deep profile")

        #expect(document.activeProfile == "fast")
        #expect(preview.profile == "deep")
        let requests = await transport.requests
        #expect(requests.map(\.method) == ["GET", "GET"])
        #expect(requests.map(\.path) == ["\(prefix)/config/delegation", "\(prefix)/config/delegation/preview?profile=deep%20profile"])
        #expect(requests.allSatisfy { $0.headers.isEmpty && $0.body == nil })
    }

    @Test(arguments: prefixes)
    func everyWriteHasItsRouteMethodBodyAndIfMatch(prefix: String) async throws {
        let transport = ConfigRecordingTransport(fixtures: ["delegation_cell"])
        let client = Self.client(prefix: prefix, transport)
        let target = LeoDelegationTarget(template: "coder", model: "", effort: "high")

        _ = try await client.setDelegationCell(profile: "fast", role: "coder", target: target, ifMatch: "r1")
        _ = try await client.setRoleUseFor(role: "coder", useFor: "writing code", ifMatch: "r1")
        _ = try await client.setActiveProfile("deep", ifMatch: "r1")
        _ = try await client.setDelegationEnabled(false, ifMatch: "r1")
        _ = try await client.setHiddenAgents(["Explore", "Plan"], ifMatch: "r1")
        _ = try await client.addDelegationRole(name: "qa", template: "reviewer", ifMatch: "r1")
        _ = try await client.renameDelegationRole("qa", to: "tester", ifMatch: "r1")
        _ = try await client.deleteDelegationRole("tester", ifMatch: "r1")
        _ = try await client.addDelegationProfile(name: "cheap", ifMatch: "r1")
        _ = try await client.renameDelegationProfile("cheap", to: "thrifty", ifMatch: "r1")
        _ = try await client.duplicateDelegationProfile("thrifty", as: "thrifty 2", ifMatch: "r1")
        _ = try await client.deleteDelegationProfile("thrifty", ifMatch: "r1")

        let requests = await transport.requests
        let base = "\(prefix)/config/delegation"
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "PUT \(base)/profiles/fast/roles/coder", "PUT \(base)/roles/coder", "PUT \(base)/active", "PUT \(base)/enabled",
            "PUT \(base)/hide-agents", "POST \(base)/roles", "POST \(base)/roles/qa/rename", "DELETE \(base)/roles/tester",
            "POST \(base)/profiles", "POST \(base)/profiles/cheap/rename", "POST \(base)/profiles/thrifty/duplicate",
            "DELETE \(base)/profiles/thrifty",
        ])
        #expect(requests.allSatisfy { $0.headers == ["If-Match": "r1"] })
        #expect(try Self.json(requests[0]) == ["template": "coder", "model": "", "effort": "high"])
        #expect(try Self.json(requests[1]) == ["use_for": "writing code"])
        #expect(try Self.json(requests[2]) == ["profile": "deep"])
        #expect(try Self.json(requests[3]) == ["enabled": false])
        #expect(try Self.json(requests[4]) == ["names": ["Explore", "Plan"]])
        #expect(try Self.json(requests[5]) == ["name": "qa", "template": "reviewer"])
        #expect(try Self.json(requests[6]) == ["new_name": "tester"])
        #expect(requests[7].body == nil)
        #expect(try Self.json(requests[8]) == ["name": "cheap"])
        #expect(try Self.json(requests[9]) == ["new_name": "thrifty"])
        #expect(try Self.json(requests[10]) == ["new_name": "thrifty 2"])
        #expect(requests[11].body == nil)
    }

    @Test func clearingTheHideListSendsAnEmptyArrayNotNothing() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["delegation_cell"])
        _ = try await Self.client(prefix: "", transport).setHiddenAgents([], ifMatch: "r1")

        let request = try #require(await transport.requests.first)
        #expect(try Self.json(request) == ["names": [String]()])
    }

    @Test func aWriteAnswersWithTheRefreshedDocument() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["delegation_cell"])
        let result = try await Self.client(prefix: "", transport).setActiveProfile("deep", ifMatch: "r1")

        #expect(result.restartRequired.agents)
        #expect(result.item?.revision == result.revision)
    }

    @Test func aBadEffortIsA422OnTheEffortField() async throws {
        let body = try #require(String(bytes: try LeoConfigFixtures.goldenData("delegation_cell_422"), encoding: .utf8))
        let transport = ConfigRecordingTransport(body: body, status: 422)

        do {
            _ = try await Self.client(prefix: "", transport).setDelegationCell(
                profile: "fast", role: "coder", target: LeoDelegationTarget(template: "coder", effort: "ludicrous"), ifMatch: "r1"
            )
            Issue.record("Expected a 422")
        } catch LeoConfigError.invalid(let errors) {
            #expect(errors.first?.field == "effort")
        }
    }

    @Test func aStaleWriteIsAConflictCarryingTheCurrentRevision() async throws {
        let body = try #require(String(bytes: try LeoConfigFixtures.goldenData("error_409"), encoding: .utf8))
        let transport = ConfigRecordingTransport(body: body, status: 409)

        do {
            _ = try await Self.client(prefix: "", transport).setDelegationEnabled(true, ifMatch: "old")
            Issue.record("Expected a 409")
        } catch LeoConfigError.conflict(let current) {
            #expect(current.hasPrefix("sha256:"))
        }
    }

    @Test func anEmptyNameIsRefusedBeforeTheRequestIsSent() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["delegation_cell"])

        await #expect(throws: LeoDaemonError.self) {
            _ = try await Self.client(prefix: "", transport).deleteDelegationProfile("", ifMatch: "r")
        }
        #expect(await transport.requests.isEmpty)
    }
}
