import Foundation
import Testing

@testable import LeoKit

/// Every body the daemon's `TestConfigAPIGolden` wrote, decoded through the
/// models the app uses. A file that fails here is a contract bug.
struct LeoConfigGoldenTests {
    private enum Shape {
        case schema, document, collection, writeResult
        case error(status: Int)
        /// No app model yet (a later slice's pane); the envelope must still be well formed.
        case envelopeOnly
    }

    private static func shape(of name: String) -> Shape {
        switch name {
        case "schema": .schema
        case "defaults", "web", "client", "template_coder": .document
        case "templates", "tasks", "environments", "hosts": .collection
        case "post_task", "post_template_duplicate", "post_template_rename", "put_defaults", "put_web", "put_template_env_secret", "delegation_cell": .writeResult
        case "error_400": .error(status: 400)
        case "error_404": .error(status: 404)
        case "error_409": .error(status: 409)
        case "error_422", "delegation_cell_422": .error(status: 422)
        case "error_428": .error(status: 428)
        default: .envelopeOnly
        }
    }

    @Test func everyStatusEntryHasAFileAndEveryFileAStatus() throws {
        let statuses = try JSONDecoder().decode([String: Int].self, from: LeoConfigFixtures.goldenData("STATUS"))
        #expect(Set(LeoConfigFixtures.goldenNames) == Set(statuses.keys))
        #expect(LeoConfigFixtures.goldenNames.count >= 28)
    }

    @Test func aSecretEnvVariableInAWriteResultSurvivesAnEdit() throws {
        let result = try LeoConfigFixtures.decode(LeoConfigWriteResult.self, "put_template_env_secret")
        let env = try #require(result.item?.values["env"])

        #expect(env.envSecretNames == ["ANTHROPIC_AUTH_TOKEN"])
        #expect(env.envEntries == ["ANTHROPIC_BASE_URL": "http://localhost:3325"])
    }

    @Test(arguments: LeoConfigFixtures.goldenNames)
    func decodesThroughTheRealModels(name: String) throws {
        switch Self.shape(of: name) {
        case .schema:
            let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, name)
            #expect(!schema.resources.isEmpty)
        case .document:
            let document = try LeoConfigFixtures.decode(LeoConfigDocument.self, name)
            #expect(document.revision.hasPrefix("sha256:"))
            #expect(!document.values.isEmpty)
        case .collection:
            let collection = try LeoConfigFixtures.decode(LeoConfigCollection.self, name)
            #expect(collection.revision.hasPrefix("sha256:"))
            #expect(collection.items.allSatisfy { !$0.name.isEmpty })
        case .writeResult:
            let result = try LeoConfigFixtures.decode(LeoConfigWriteResult.self, name)
            #expect(result.revision.hasPrefix("sha256:"))
            #expect(result.item != nil)
        case .error, .envelopeOnly:
            let envelope = try LeoDaemonEnvelope<LeoConfigValue>.decode(try LeoConfigFixtures.goldenData(name))
            #expect(envelope.ok == (try LeoConfigFixtures.goldenStatus(name) < 400))
        }
    }

    @Test(arguments: LeoConfigFixtures.goldenNames.filter { name in
        if case .error = Self.shape(of: name) { true } else { false }
    })
    func theClientMapsAnErrorBodyToItsStatus(name: String) async throws {
        guard case .error(let status) = Self.shape(of: name) else { return }
        #expect(try LeoConfigFixtures.goldenStatus(name) == status)
        let body = try #require(String(bytes: try LeoConfigFixtures.goldenData(name), encoding: .utf8))
        let transport = ConfigRecordingTransport(body: body, status: status)
        let client = LeoConfigHTTPClient(prefix: "", transport: transport)

        do {
            _ = try await client.update("templates", name: "coder", patch: [:], ifMatch: "sha256:r")
            Issue.record("Expected \(name) to throw")
        } catch let error as LeoConfigError {
            switch (status, error) {
            case (409, .conflict(let revision)): #expect(revision.hasPrefix("sha256:"))
            case (422, .invalid(let errors)): #expect(!errors.isEmpty)
            case (428, .revisionRequired): break
            default: Issue.record("\(name): unexpected \(error)")
            }
        } catch let error as LeoDaemonError {
            #expect([400, 404].contains(status), "\(name): \(error)")
        }
    }
}
