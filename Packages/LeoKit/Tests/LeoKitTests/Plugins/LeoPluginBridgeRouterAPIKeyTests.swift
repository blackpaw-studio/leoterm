import Foundation
import Testing

@testable import LeoKit

private let usageID = "studio.blackpaw.usage"
private let pastedKey = "sk-deepseek-SECRET-0123456789"
private let deepseek = LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.deepseek.com")
private let service = "Leo Plugin API Key"

/// Serves canned responses by absolute URL for the API-key fetch tests only.
private final class APIKeyStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var redirects: [String: String] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    static func redirect(_ url: String, to target: String) { lock.withLock { redirects[url] = target } }
    static func seen(_ url: String) -> [URLRequest] { lock.withLock { requests[url] ?? [] } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url?.absoluteString else { return }
        let target: String? = Self.lock.withLock {
            Self.requests[url, default: []].append(request)
            return Self.redirects[url]
        }
        if let target {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target])!
            var next = URLRequest(url: URL(string: target)!)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"is_available":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor private final class FakeKeyPicker: LeoPluginCredentialPicking {
    var answer: LeoPluginAPIKeyEntry?
    /// Runs while the sheet is "open", before the answer comes back.
    var whileOpen: (@MainActor () -> Void)?
    private(set) var asked: [(LeoPluginAPIKeyProvider, String)] = []
    init(answer: LeoPluginAPIKeyEntry?) { self.answer = answer }
    func pickFolder(for kind: LeoPluginCredentialKind) async -> String? { nil }
    func pickAPIKey(for provider: LeoPluginAPIKeyProvider, pluginName: String) async -> LeoPluginAPIKeyEntry? {
        asked.append((provider, pluginName))
        whileOpen?()
        return answer
    }
}

private struct NoAccounts: LeoPluginCredentialResolving {
    func resolve(_ grant: LeoPluginCredentialGrant, allowUI: Bool) throws(LeoPluginCredentialError) -> LeoPluginFetchCredential {
        throw .notFound
    }
}

private func manifest() -> LeoPluginManifest {
    LeoPluginManifest(
        id: usageID, name: "Usage", version: "1.0.0", apiVersion: 2, main: "main.js",
        permissions: LeoPluginPermissions(network: ["api.deepseek.com", "evil.example.com"], credentials: [.codex], apiKeys: [deepseek]))
}

@MainActor private final class APIKeyRig {
    let picker: FakeKeyPicker
    let keychain = PluginFakeKeychain()
    let store: LeoPluginStore
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("apikey-\(UUID().uuidString)")
    let router: LeoPluginBridgeRouter
    private let box = Box()
    private let sink = Sink()

    final class Box: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
    @MainActor final class Sink { var events: [LeoPluginEvent] = [] }

    init(answer: LeoPluginAPIKeyEntry? = LeoPluginAPIKeyEntry(key: "  \(pastedKey)\n", name: "Work"), fetcher: (any LeoPluginFetching)? = nil) {
        picker = FakeKeyPicker(answer: answer)
        store = LeoPluginStore(root: root)
        let manifest = manifest()
        try? store.update { $0.registerDev(manifest, path: "/tmp/usage") }
        let box = self.box
        let sink = self.sink
        let engine = LeoPluginPermissionEngine(permissions: manifest.permissions)
        router = LeoPluginBridgeRouter(
            LeoPluginBridgeRouter.Dependencies(
                identity: LeoPluginIdentity(id: manifest.id, name: manifest.name), manifest: manifest, engine: engine,
                gate: LeoPluginActionGate(grants: manifest.permissions, now: { box.now }),
                fetcher: fetcher
                    ?? LeoPluginFetcher(pluginID: usageID, engine: engine, configure: { $0.protocolClasses = [APIKeyStubProtocol.self] }),
                secrets: nil, timers: LeoPluginTimers(scheduler: PluginManualScheduler(), onFire: { _ in }), slots: LeoPluginSlotStore(),
                actions: PluginFakeActions(), agents: { [] }, now: { box.now }, send: { sink.events.append($0) },
                credentials: LeoPluginCredentialServices(
                    picker: picker, resolver: NoAccounts(), grants: store, home: "/Users/evan",
                    apiKeys: LeoPluginAPIKeyVault(reader: keychain, writer: keychain))))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var events: [LeoPluginEvent] { sink.events }

    func gestureRef(gesture: Bool = true) -> String {
        let minted = gesture ? LeoPluginGesture(origin: .click, mintedAt: box.now) : nil
        guard case .callback(let ref, _, _, _) = router.callbackEvent(id: "add", payload: .null, gesture: minted, slot: nil) else { return "" }
        return ref
    }

    func reply(_ id: String) -> LeoPluginReplyOutcome? {
        for case .reply(let replyID, let outcome) in events where replyID == id { return outcome }
        return nil
    }

    func rejection(_ id: String) -> String {
        if case .rejected(let reason)? = reply(id) { return reason }
        return "not rejected: \(String(describing: reply(id)))"
    }

    func add(_ id: String, provider: String? = "deepseek", kind: String = "api-key", gesture: Bool = true) async {
        router.handle(.credentialsAdd(id: id, kind: kind, provider: provider, ref: gestureRef(gesture: gesture)))
        await settle()
    }

    /// The grant id of a key added through the bridge.
    func addedGrantID() async throws -> String {
        await add("add")
        guard case .value(.object(let fields))? = reply("add"), case .string(let id)? = fields["id"] else {
            throw CancellationError()
        }
        return id
    }

    func fetch(_ id: String, url: String, headers: [String: String]? = nil, credential: String) async {
        router.handle(.fetch(id: id, url: url, init: LeoPluginFetchInit(headers: headers, credential: credential)))
        for _ in 0..<200 where reply(id) == nil { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func settle() async { for _ in 0..<200 { await Task.yield() } }

    /// Everything that left the app for the plugin, plus what was saved to disk.
    func everythingVisible() throws -> String {
        let registry = (try? String(contentsOf: root.appendingPathComponent("registry.json"), encoding: .utf8)) ?? ""
        return events.map { String(describing: $0) }.joined(separator: "\n") + registry
            + String(describing: store.registry)
    }
}

@MainActor struct LeoPluginBridgeRouterAPIKeyTests {
    @Test func addingAKeyReturnsAHandleAndKeepsTheKeyOnlyInTheKeychain() async throws {
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        #expect(
            rig.reply("add")
                == .value(.object(["id": .string(id), "kind": .string("api-key"), "provider": .string("deepseek"), "name": .string("Work")])))
        #expect(rig.keychain.items == ["\(service)|\(usageID)/\(id)": pastedKey])
        #expect(rig.picker.asked.map(\.0) == [deepseek])
        #expect(rig.picker.asked.map(\.1) == ["Usage"])
        #expect(rig.store.grants(pluginID: usageID).map(\.subject) == [.apiKey(provider: "deepseek", name: "Work")])
        let visible = try rig.everythingVisible()
        #expect(visible.contains("deepseek"))
        #expect(!visible.contains(pastedKey))
        #expect(!visible.contains("0123456789"))
    }

    @Test func aBlankNameDefaultsToTheProvidersLabel() async throws {
        let rig = APIKeyRig(answer: LeoPluginAPIKeyEntry(key: pastedKey, name: "  "))
        _ = try await rig.addedGrantID()
        #expect(rig.store.grants(pluginID: usageID).map(\.subject) == [.apiKey(provider: "deepseek", name: "DeepSeek")])
    }

    @Test func cancellingTheSheetAddsNothing() async {
        let rig = APIKeyRig(answer: nil)
        await rig.add("add")
        #expect(rig.reply("add") == .value(.null))
        #expect(rig.keychain.items.isEmpty)
        #expect(rig.store.grants(pluginID: usageID).isEmpty)
    }

    @Test func addingWithoutAGestureOpensNoSheet() async {
        let rig = APIKeyRig()
        await rig.add("add", gesture: false)
        #expect(rig.rejection("add").hasPrefix("gestureRequired"))
        #expect(rig.picker.asked.isEmpty)
    }

    @Test(arguments: [("openrouter", "api-key"), (nil, "api-key"), ("deepseek", "codex")] as [(String?, String)])
    func anUnapprovedOrMisplacedProviderIsDenied(provider: String?, kind: String) async {
        let rig = APIKeyRig()
        await rig.add("add", provider: provider, kind: kind)
        #expect(rig.rejection("add").hasPrefix("credentialPermissionDenied"))
        #expect(rig.picker.asked.isEmpty)
        #expect(rig.keychain.items.isEmpty)
    }

    @Test(arguments: ["", "sk with space", String(repeating: "k", count: 513), "sk-ключ"])
    func anInvalidPastedKeyIsRefusedAndNothingIsSaved(key: String) async {
        let rig = APIKeyRig(answer: LeoPluginAPIKeyEntry(key: key, name: "Work"))
        await rig.add("add")
        #expect(rig.rejection("add").hasPrefix("credentialInvalid"))
        #expect(rig.keychain.items.isEmpty)
        #expect(rig.store.grants(pluginID: usageID).isEmpty)
    }

    @Test func listShowsTheKeyHandleAndRemoveDeletesGrantAndItem() async throws {
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        rig.router.handle(.credentialsList(id: "list"))
        guard case .value(.array(let handles))? = rig.reply("list") else { Issue.record("no list"); return }
        #expect(handles == [.object(["id": .string(id), "kind": .string("api-key"), "provider": .string("deepseek"), "name": .string("Work")])])

        rig.router.handle(.credentialsRemove(id: "rm", credential: id))
        #expect(rig.reply("rm") == .value(.null))
        #expect(rig.store.grants(pluginID: usageID).isEmpty)
        #expect(rig.keychain.items.isEmpty)
    }

    @Test func aRemoveWhoseKeychainDeleteFailsKeepsTheGrantSoItCanBeRetried() async throws {
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        rig.keychain.failDeletes(true)

        rig.router.handle(.credentialsRemove(id: "rm", credential: id))
        #expect(rig.rejection("rm").hasPrefix("credentialPermissionDenied"))
        #expect(!rig.rejection("rm").contains(pastedKey))
        #expect(rig.store.grants(pluginID: usageID).map(\.id) == [id])
        #expect(rig.keychain.items.count == 1)

        rig.keychain.failDeletes(false)
        rig.router.handle(.credentialsRemove(id: "rm2", credential: id))
        #expect(rig.reply("rm2") == .value(.null))
        #expect(rig.store.grants(pluginID: usageID).isEmpty)
        #expect(rig.keychain.items.isEmpty)
    }

    @Test(arguments: [
        LeoPluginPermissions(network: ["api.deepseek.com", "evil.example.com"], credentials: [.codex]),
        LeoPluginPermissions(
            network: ["api.deepseek.com", "evil.example.com"], credentials: [.codex],
            apiKeys: [LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "evil.example.com")]),
    ])
    func anAddWhoseApprovalChangedWhileTheSheetWasOpenIsRefusedAndLeavesNoKey(changed: LeoPluginPermissions) async {
        let rig = APIKeyRig()
        let store = rig.store
        rig.picker.whileOpen = { try? store.update { $0.approve(usageID, permissions: changed) } }

        await rig.add("add")

        #expect(rig.rejection("add").hasPrefix("credentialPermissionDenied"))
        #expect(rig.keychain.items.isEmpty)
        #expect(rig.store.grants(pluginID: usageID).isEmpty)
    }

    @Test func aFetchToTheBoundHostCarriesTheBearerKey() async throws {
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        await rig.fetch("f", url: "https://api.deepseek.com/user/balance", credential: id)
        guard case .value? = rig.reply("f") else { Issue.record("fetch failed: \(rig.rejection("f"))"); return }
        let request = try #require(APIKeyStubProtocol.seen("https://api.deepseek.com/user/balance").first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(pastedKey)")
        #expect(!(try rig.everythingVisible()).contains(pastedKey))
    }

    @Test func aFetchToAnotherAllowedHostIsAHostMismatch() async throws {
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        await rig.fetch("f", url: "https://evil.example.com/steal", credential: id)
        #expect(rig.rejection("f").hasPrefix("credentialHostMismatch"))
        #expect(APIKeyStubProtocol.seen("https://evil.example.com/steal").isEmpty)
    }

    @Test func aRedirectOffTheBoundHostIsAHostMismatch() async throws {
        APIKeyStubProtocol.redirect("https://api.deepseek.com/hop", to: "https://evil.example.com/hop")
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        await rig.fetch("f", url: "https://api.deepseek.com/hop", credential: id)
        #expect(rig.rejection("f").hasPrefix("credentialHostMismatch"))
        #expect(APIKeyStubProtocol.seen("https://evil.example.com/hop").isEmpty)
    }

    @Test func aCallerAuthorizationHeaderInAnyCaseConflicts() async throws {
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        await rig.fetch("f", url: "https://api.deepseek.com/conflict", headers: ["AUTHORIZATION": "Bearer mine"], credential: id)
        #expect(rig.rejection("f").hasPrefix("credentialHeaderConflict"))
        #expect(APIKeyStubProtocol.seen("https://api.deepseek.com/conflict").isEmpty)
    }

    @Test func aMissingKeychainItemIsCredentialInvalid() async throws {
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        try rig.keychain.delete(service: service, account: "\(usageID)/\(id)")
        await rig.fetch("f", url: "https://api.deepseek.com/missing", credential: id)
        #expect(rig.rejection("f").hasPrefix("credentialInvalid"))
        #expect(APIKeyStubProtocol.seen("https://api.deepseek.com/missing").isEmpty)
    }

    @Test func aKeyThatNeedsKeychainUIIsAuthorizedFromAClick() async throws {
        let rig = APIKeyRig()
        let id = try await rig.addedGrantID()
        rig.keychain.requireUI(service: service, account: "\(usageID)/\(id)")
        await rig.fetch("f", url: "https://api.deepseek.com/ui", credential: id)
        #expect(rig.rejection("f").hasPrefix("credentialNeedsAuthorization"))

        rig.router.handle(.credentialsAuthorize(id: "auth", credential: id, ref: rig.gestureRef()))
        await rig.settle()
        #expect(rig.reply("auth") == .value(.null))
    }
}
