import Foundation
import Testing

@testable import LeoKit

struct LeoConfigClientTests {
    static let prefixes = ["", "/api/v1"]

    private static func client(prefix: String, _ transport: ConfigRecordingTransport) -> LeoConfigHTTPClient {
        LeoConfigHTTPClient(prefix: prefix, transport: transport)
    }

    private static func json(_ request: LeoHTTPRequest) throws -> [String: Any] {
        let body = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: routes

    @Test(arguments: prefixes)
    func readsUseGetWithoutIfMatch(prefix: String) async throws {
        let transport = ConfigRecordingTransport(fixtures: ["schema", "web", "templates", "template_coder", "version"])
        let client = Self.client(prefix: prefix, transport)

        _ = try await client.schema()
        _ = try await client.document("web")
        _ = try await client.collection("templates")
        _ = try await client.item("templates", name: "my coder")
        _ = try await client.versionInfo()

        let requests = await transport.requests
        #expect(requests.map(\.method) == Array(repeating: "GET", count: 5))
        #expect(requests.map(\.path) == [
            "\(prefix)/config/schema", "\(prefix)/config/web", "\(prefix)/config/templates",
            "\(prefix)/config/templates/my%20coder", "\(prefix)/version",
        ])
        #expect(requests.allSatisfy { $0.headers.isEmpty && $0.body == nil })
    }

    @Test(arguments: prefixes)
    func writesCarryIfMatchAndTheirRoutes(prefix: String) async throws {
        let transport = ConfigRecordingTransport(fixtures: ["write_result"])
        let client = Self.client(prefix: prefix, transport)

        _ = try await client.update("web", name: nil, patch: ["port": .int(9000)], ifMatch: "sha256:r1")
        _ = try await client.update("templates", name: "coder", patch: ["model": .string("x")], ifMatch: "sha256:r1")
        _ = try await client.add("templates", name: "new", ifMatch: "sha256:r1")
        _ = try await client.rename("templates", name: "coder", to: "coder2", ifMatch: "sha256:r1")
        _ = try await client.duplicate("templates", name: "coder", as: "coder3", ifMatch: "sha256:r1")
        _ = try await client.delete("hosts", name: "old", ifMatch: "sha256:r1")

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["PUT", "PUT", "POST", "POST", "POST", "DELETE"])
        #expect(requests.map(\.path) == [
            "\(prefix)/config/web", "\(prefix)/config/templates/coder", "\(prefix)/config/templates",
            "\(prefix)/config/templates/coder/rename", "\(prefix)/config/templates/coder/duplicate",
            "\(prefix)/config/hosts/old",
        ])
        #expect(requests.allSatisfy { $0.headers == ["If-Match": "sha256:r1"] })
        #expect(requests[5].body == nil)
        #expect(try Self.json(requests[2]) as NSDictionary == ["name": "new"])
        #expect(try Self.json(requests[3]) as NSDictionary == ["new_name": "coder2"])
        #expect(try Self.json(requests[4]) as NSDictionary == ["new_name": "coder3"])
    }

    @Test func addCarriesTheRequiredExtraFields() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["write_result"])
        _ = try await Self.client(prefix: "", transport).add("tasks", name: "t", values: ["schedule": .string("* * * * *")], ifMatch: "r")

        let request = try #require(await transport.requests.first)
        #expect(try Self.json(request) as NSDictionary == ["name": "t", "schedule": "* * * * *"])
    }

    // MARK: bodies

    @Test func aPartialPutCarriesOnlyTheChangedKeys() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["write_result"])
        _ = try await Self.client(prefix: "", transport).update(
            "templates", name: "coder", patch: ["max_turns": .null, "env": .map(["A": "1"]), "idle_suspend": .bool(false)], ifMatch: "r"
        )

        let request = try #require(await transport.requests.first)
        let values = try #require(try Self.json(request)["values"] as? [String: Any])
        #expect(Set(values.keys) == ["max_turns", "env", "idle_suspend"])
        #expect(values["max_turns"] is NSNull)
        #expect(values["env"] as? [String: String] == ["A": "1"])
        #expect(values["idle_suspend"] as? Bool == false)
    }

    @Test func secretsAreReplacedOrClearedNeverEchoed() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["write_result"])
        let client = Self.client(prefix: "", transport)
        _ = try await client.update("hosts", name: "a", patch: ["token": .secretReplace("s3cret")], ifMatch: "r")
        _ = try await client.update("hosts", name: "a", patch: ["token": .secretClear], ifMatch: "r")

        let requests = await transport.requests
        let replace = try #require(try Self.json(requests[0])["values"] as? [String: Any])
        let clear = try #require(try Self.json(requests[1])["values"] as? [String: Any])
        #expect(replace["token"] as? [String: String] == ["replace": "s3cret"])
        #expect(clear["token"] as? [String: Bool] == ["clear": true])
    }

    @Test func aWriteResultDecodesWithItsRestartFlags() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["write_result"])
        let result = try await Self.client(prefix: "", transport).update("web", name: nil, patch: [:], ifMatch: "r")

        #expect(result.revision == "sha256:bb22")
        #expect(result.restartRequired.agents)
        #expect(!result.restartRequired.service)
    }

    @Test(arguments: [200, 201, 202])
    func everySuccessStatusIsAccepted(status: Int) async throws {
        let transport = ConfigRecordingTransport(fixtures: ["write_result"], status: status)
        _ = try await Self.client(prefix: "", transport).add("templates", name: "n", ifMatch: "r")
    }

    // MARK: errors

    @Test func aStaleRevisionIsAConflictCarryingTheCurrentOne() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["error_409"], status: 409)
        await #expect(throws: LeoConfigError.conflict(currentRevision: "sha256:cc33")) {
            _ = try await Self.client(prefix: "", transport).update("web", name: nil, patch: [:], ifMatch: "old")
        }
    }

    @Test func invalidValuesAreFieldErrors() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["error_422"], status: 422)
        await #expect(throws: LeoConfigError.invalid([
            LeoConfigFieldError(field: "max_turns", message: "must be at least 1"),
            LeoConfigFieldError(field: "harness_options.sandbox", message: "unknown value \"x\""),
            LeoConfigFieldError(field: "", message: "templates.old: workspace is required"),
        ])) {
            _ = try await Self.client(prefix: "", transport).update("templates", name: "a", patch: [:], ifMatch: "r")
        }
    }

    @Test func a422WithoutAnErrorsListFallsBackToAFormLevelMessage() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"error":"bad name","code":"invalid"}"#, status: 422)
        await #expect(throws: LeoConfigError.invalid([LeoConfigFieldError(field: "", message: "bad name")])) {
            _ = try await Self.client(prefix: "", transport).add("templates", name: "x", ifMatch: "r")
        }
    }

    @Test func aMissingIfMatchIsRevisionRequired() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"error":"If-Match required","code":"revision_required"}"#, status: 428)
        await #expect(throws: LeoConfigError.revisionRequired) {
            _ = try await Self.client(prefix: "", transport).delete("hosts", name: "a", ifMatch: "r")
        }
    }

    @Test func aMissingSchemaRouteMeansTheDaemonIsTooOld() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"error":"not found"}"#, status: 404)
        await #expect(throws: LeoConfigError.unsupported) {
            _ = try await Self.client(prefix: "/api/v1", transport).schema()
        }
    }

    @Test func aMissingItemIsAnOrdinaryNotFound() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"error":"no template x","code":"not_found"}"#, status: 404)
        await #expect(throws: LeoDaemonError.daemon(code: "not_found", message: "no template x", matches: [])) {
            _ = try await Self.client(prefix: "", transport).item("templates", name: "x")
        }
    }

    @Test func otherFailuresKeepTheDaemonsCodeAndMessage() async throws {
        let transport = ConfigRecordingTransport(body: #"{"ok":false,"error":"leo.yaml does not load","code":"config_unavailable"}"#, status: 503)
        await #expect(throws: LeoDaemonError.daemon(code: "config_unavailable", message: "leo.yaml does not load", matches: [])) {
            _ = try await Self.client(prefix: "", transport).document("web")
        }
    }

    @Test func aBodylessFailureIsNamedByItsStatus() async throws {
        let transport = ConfigRecordingTransport(body: "", status: 401)
        await #expect(throws: LeoDaemonError.daemon(code: "unauthorized", message: "HTTP 401", matches: [])) {
            _ = try await Self.client(prefix: "/api/v1", transport).document("web")
        }
    }

    @Test func aMissingNameIsRejectedBeforeAnyRequest() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["write_result"])
        await #expect(throws: LeoDaemonError.self) {
            _ = try await Self.client(prefix: "", transport).delete("templates", name: "", ifMatch: "r")
        }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: version and capability

    @Test func versionInfoDecodesCapabilitiesAndIgnoresUnknownOnes() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["version"])
        let info = try await Self.client(prefix: "", transport).versionInfo()

        #expect(info.version == "0.52.0")
        #expect(info.supports(LeoConfigAPI.capability))
        #expect(LeoConfigAPI.isSupported(by: info))
        #expect(!LeoConfigAPI.isSupported(by: LeoDaemonVersionInfo(version: "0.40.0", capabilities: ["machine_stats"])))
    }

    @Test func helloFeaturesKnowTheConfigAPI() {
        #expect(LeoDaemonFeatures(["config_api"]).contains(.configAPI))
    }

    // MARK: the transports' own clients

    @Test func theSocketClientBuildsAnUnprefixedConfigClient() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["web"])
        let socket = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: transport)
        _ = try await #require(socket.configClient()).document("web")

        #expect(await transport.requests.map(\.path) == ["/config/web"])
        #expect(await transport.socketPaths == ["/tmp/leo.sock"])
    }

    @Test func theWebClientBuildsAnApiV1ConfigClient() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["web"])
        _ = try await LeoWebDaemonClient(transport: transport).configClient().document("web")

        #expect(await transport.requests.map(\.path) == ["/api/v1/config/web"])
    }

    @Test func aDaemonClientWithoutAConfigRouteGivesNone() {
        #expect(NoConfigDaemonClient().configClient() == nil)
    }
}

/// Answers each request from a fixture or a literal body, recording what it
/// was sent. Serves both the socket and the web transport protocols.
actor ConfigRecordingTransport: LeoDaemonTransport, LeoWebTransport {
    private let reply: @Sendable (LeoHTTPRequest) -> (status: Int, body: Data)
    private(set) var requests: [LeoHTTPRequest] = []
    private(set) var socketPaths: [String] = []

    /// A read is answered by the fixture its route names when `fixtures`
    /// lists it, and every request else by the first fixture.
    init(fixtures: [String], status: Int = 200) {
        let bodies = Dictionary(uniqueKeysWithValues: fixtures.map { ($0, (try? LeoConfigFixtures.data($0)) ?? Data()) })
        let fallback = fixtures.first.flatMap { bodies[$0] } ?? Data()
        reply = { request in
            let route = request.path.split(separator: "?")[0]
            let name = request.method == "GET" ? Self.fixtureName(forRoute: String(route)) : nil
            return (status, name.flatMap { bodies[$0] } ?? fallback)
        }
    }

    init(body: String, status: Int) {
        reply = { _ in (status, Data(body.utf8)) }
    }

    func send(_ request: LeoHTTPRequest, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        let answer = reply(request)
        return LeoHTTPResponse(status: answer.status, body: answer.body)
    }

    func send(_ request: LeoHTTPRequest, socketPath: String, timeout: TimeInterval) async throws -> LeoHTTPResponse {
        socketPaths.append(socketPath)
        return try await send(request, timeout: timeout)
    }

    nonisolated func events(path _: String) -> AsyncThrowingStream<LeoSSEEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private static func fixtureName(forRoute route: String) -> String? {
        if route.hasSuffix("/schema") { return "schema" }
        if route.hasSuffix("/version") { return "version" }
        if route.hasSuffix("/templates/my%20coder") { return "template_coder" }
        return route.split(separator: "/").last.map(String.init)
    }
}

private struct NoConfigDaemonClient: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.transport("x") }
    func start(_ name: String) async throws {}
    func stop(_ name: String, wakeOnMessage: Bool?) async throws {}
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.transport("x") }
    func reset(_ name: String) async throws {}
    func setTemplate(_ name: String, template: String) async throws {}
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.transport("x") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws {}
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.transport("x") }
    func logs(_ name: String, lines: Int?) async throws -> String { "" }
}
