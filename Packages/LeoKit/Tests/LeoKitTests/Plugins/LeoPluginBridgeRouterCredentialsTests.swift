import Foundation
import Testing

@testable import LeoKit

private let usageID = "studio.blackpaw.usage"

@MainActor private final class FakePicker: LeoPluginCredentialPicking {
    var answer: String?
    /// When set, the pick names this machine (a remote account); else it is a folder on this Mac.
    var machine: LeoHostID = .local
    private(set) var asked: [LeoPluginCredentialKind] = []
    init(answer: String?) { self.answer = answer }
    func pickFolder(for kind: LeoPluginCredentialKind) async -> String? {
        asked.append(kind)
        return answer
    }

    func pickAccount(for kind: LeoPluginCredentialKind) async -> LeoPluginCredentialSelection? {
        asked.append(kind)
        return answer.map { LeoPluginCredentialSelection(machine: machine, path: $0) }
    }
}

private final class FakeResolver: LeoPluginCredentialResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, Bool)] = []
    var failure: LeoPluginCredentialError?
    var calls: [(path: String, allowUI: Bool)] { lock.withLock { _calls.map { (path: $0.0, allowUI: $0.1) } } }

    func resolve(_ grant: LeoPluginCredentialGrant, allowUI: Bool) throws(LeoPluginCredentialError) -> LeoPluginFetchCredential {
        let failure = lock.withLock { () -> LeoPluginCredentialError? in
            _calls.append((grant.accountPath ?? "", allowUI))
            return self.failure
        }
        if let failure { throw failure }
        return LeoPluginFetchCredential(boundHost: grant.accountKind?.boundHost ?? "", headers: ["Authorization": "Bearer t"])
    }
}

private final class FakeGrantStore: LeoPluginCredentialGrantStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var registry = LeoPluginRegistry()
    private var counter = 0

    init(manifests: [LeoPluginManifest]) {
        for manifest in manifests { registry.registerDev(manifest, path: "/tmp/\(manifest.id)") }
    }

    func grants(pluginID: String) -> [LeoPluginCredentialGrant] { lock.withLock { registry.grants(for: pluginID) } }

    func addGrant(pluginID: String, kind: LeoPluginCredentialKind, path: String, machine: LeoHostID) throws -> LeoPluginCredentialGrant? {
        lock.withLock {
            counter += 1
            return registry.addGrant(pluginID: pluginID, kind: kind, path: path, id: "grant-\(counter)", machine: machine)
        }
    }

    func addAPIKeyGrant(pluginID: String, provider: String, host: String, name: String, id: String) throws -> LeoPluginCredentialGrant? {
        lock.withLock { registry.addAPIKeyGrant(pluginID: pluginID, provider: provider, host: host, name: name, id: id) }
    }

    func removeGrant(pluginID: String, grantID: String) throws {
        lock.withLock { registry.removeGrant(pluginID: pluginID, grantID: grantID) }
    }

    /// The registry as it would be saved to registry.json.
    func encodedRegistry() throws -> Data { try lock.withLock { try JSONEncoder().encode(registry) } }
}

private func manifest(id: String = usageID, apiVersion: Int = 2, credentials: [LeoPluginCredentialKind] = [.claudeCode, .codex]) -> LeoPluginManifest {
    LeoPluginManifest(
        id: id, name: "Usage", version: "1.0.0", apiVersion: apiVersion, main: "main.js",
        permissions: LeoPluginPermissions(network: ["api.anthropic.com", "chatgpt.com"], credentials: credentials),
        contributes: LeoPluginContributions(commands: [LeoPluginCommandContribution(id: "add-codex", title: "Add Codex Account…")]))
}

@MainActor private final class CredentialRig {
    let picker: FakePicker
    let resolver = FakeResolver()
    let grants: FakeGrantStore
    let fetcher = PluginFakeFetcher()
    let actions = PluginFakeActions()
    let router: LeoPluginBridgeRouter
    private let box = Box()
    private let sink = Sink()

    final class Box: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
    @MainActor final class Sink { var events: [LeoPluginEvent] = [] }

    init(
        manifest: LeoPluginManifest = manifest(), pickerAnswer: String? = "/Users/evan/.codex", fetching: (any LeoPluginFetching)? = nil,
        remote: (any LeoPluginRemoteCredentialForwarding)? = nil
    ) {
        picker = FakePicker(answer: pickerAnswer)
        grants = FakeGrantStore(manifests: [manifest, LeoPluginManifest.other])
        let permissions = manifest.permissions
        let box = self.box
        let sink = self.sink
        let scheduler = PluginManualScheduler()
        router = LeoPluginBridgeRouter(
            LeoPluginBridgeRouter.Dependencies(
                identity: LeoPluginIdentity(id: manifest.id, name: manifest.name), manifest: manifest,
                engine: LeoPluginPermissionEngine(permissions: permissions),
                gate: LeoPluginActionGate(grants: permissions, now: { box.now }), fetcher: fetching ?? fetcher, secrets: nil,
                timers: LeoPluginTimers(scheduler: scheduler, onFire: { _ in }), slots: LeoPluginSlotStore(), actions: actions,
                agents: { [] }, now: { box.now }, send: { sink.events.append($0) },
                credentials: LeoPluginCredentialServices(picker: picker, resolver: resolver, grants: grants, home: "/Users/evan", remote: remote)))
    }

    var events: [LeoPluginEvent] { sink.events }
    func advance(_ seconds: TimeInterval) { box.now = box.now.addingTimeInterval(seconds) }

    /// A callback delivered for a click; returns its ref.
    func gestureRef(gesture: Bool = true) -> String {
        let minted = gesture ? LeoPluginGesture(origin: .click, mintedAt: box.now) : nil
        guard case .callback(let ref, _, _, _) = router.callbackEvent(id: "add", payload: .null, gesture: minted, slot: nil) else { return "" }
        return ref
    }

    func reply(_ id: String) -> LeoPluginReplyOutcome? {
        for case .reply(let replyID, let outcome) in events where replyID == id { return outcome }
        return nil
    }

    func settle() async { for _ in 0..<80 { await Task.yield() } }
}

extension LeoPluginManifest {
    fileprivate static let other = LeoPluginManifest(
        id: "studio.other.plugin", name: "Other", version: "1.0.0", apiVersion: 2, main: "main.js",
        permissions: LeoPluginPermissions(network: ["chatgpt.com"], credentials: [.codex]))
}

private func rejection(_ outcome: LeoPluginReplyOutcome?) -> String? {
    if case .rejected(let reason)? = outcome { return reason }
    return nil
}

extension LeoPluginBridgeRouterTests {
    @Test func addWithoutAGestureIsRejectedAndNoPickerOpens() async {
        let rig = CredentialRig()
        rig.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: nil))
        rig.router.handle(.credentialsAdd(id: "r2", kind: "codex", ref: rig.gestureRef(gesture: false)))
        await rig.settle()
        #expect(rejection(rig.reply("r1"))?.hasPrefix("gestureRequired") == true)
        #expect(rejection(rig.reply("r2"))?.hasPrefix("gestureRequired") == true)
        #expect(rig.picker.asked.isEmpty)
    }

    @Test func aGestureOlderThanThirtySecondsIsRejected() async {
        let rig = CredentialRig()
        let ref = rig.gestureRef()
        rig.advance(31)
        rig.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: ref))
        await rig.settle()
        #expect(rejection(rig.reply("r1"))?.hasPrefix("gestureRequired") == true)
        #expect(rig.picker.asked.isEmpty)
    }

    @Test func aGestureOpensAtMostOnePicker() async {
        let rig = CredentialRig()
        let ref = rig.gestureRef()
        rig.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: ref))
        rig.router.handle(.credentialsAdd(id: "r2", kind: "codex", ref: ref))
        await rig.settle()
        #expect(rig.picker.asked == [.codex])
        #expect(rejection(rig.reply("r2"))?.hasPrefix("gestureRequired") == true)
    }

    @Test func aCredentialPromptStillAllowsTheCallbacksFollowUp() async {
        let rig = CredentialRig()
        let ref = rig.gestureRef()
        rig.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: ref))
        await rig.settle()
        rig.router.handle(.callbackResult(ref: ref, action: .copy("x")))
        #expect(rig.actions.performed.count == 1)
    }

    @Test func aV1PluginAndAnUnapprovedKindAreDenied() async {
        let v1 = CredentialRig(manifest: manifest(apiVersion: 1))
        v1.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: v1.gestureRef()))
        v1.router.handle(.credentialsList(id: "r2"))
        let codexOnly = CredentialRig(manifest: manifest(credentials: [.codex]))
        codexOnly.router.handle(.credentialsAdd(id: "r1", kind: "claude-code", ref: codexOnly.gestureRef()))
        codexOnly.router.handle(.credentialsAdd(id: "r2", kind: "gemini", ref: codexOnly.gestureRef()))
        await v1.settle()
        await codexOnly.settle()
        #expect(rejection(v1.reply("r1"))?.hasPrefix("credentialPermissionDenied") == true)
        #expect(rejection(v1.reply("r2"))?.hasPrefix("credentialPermissionDenied") == true)
        #expect(rejection(codexOnly.reply("r1"))?.hasPrefix("credentialPermissionDenied") == true)
        #expect(rejection(codexOnly.reply("r2"))?.hasPrefix("credentialPermissionDenied") == true)
        #expect(v1.picker.asked.isEmpty && codexOnly.picker.asked.isEmpty)
    }

    @Test func cancellingThePickerRepliesNullAndGrantsNothing() async {
        let rig = CredentialRig(pickerAnswer: nil)
        rig.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: rig.gestureRef()))
        await rig.settle()
        #expect(rig.reply("r1") == .value(.null))
        #expect(rig.grants.grants(pluginID: usageID).isEmpty)
    }

    @Test func addValidatesWithUIThenListShowsTheHandle() async {
        let rig = CredentialRig()
        rig.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: rig.gestureRef()))
        await rig.settle()
        let handle: LeoJSONValue = .object([
            "id": .string("grant-1"), "kind": .string("codex"), "label": .string(".codex"), "path": .string("~/.codex"),
        ])
        #expect(rig.reply("r1") == .value(handle))
        #expect(rig.resolver.calls.map(\.allowUI) == [true])
        rig.router.handle(.credentialsList(id: "r2"))
        #expect(rig.reply("r2") == .value(.array([handle])))
    }

    @Test func anAccountWhoseTokenCantBeReadIsNotGranted() async {
        let rig = CredentialRig()
        rig.resolver.failure = .invalid
        rig.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: rig.gestureRef()))
        await rig.settle()
        #expect(rejection(rig.reply("r1"))?.hasPrefix("credentialInvalid") == true)
        #expect(rig.grants.grants(pluginID: usageID).isEmpty)
    }

    @Test func anotherPluginsGrantIsUnknownEverywhere() async throws {
        let rig = CredentialRig()
        let foreign = try #require(try rig.grants.addGrant(pluginID: "studio.other.plugin", kind: .codex, path: "/Users/evan/.codex"))
        rig.router.handle(.fetch(id: "r1", url: "https://chatgpt.com/backend-api/wham/usage", init: LeoPluginFetchInit(credential: foreign.id)))
        rig.router.handle(.credentialsAuthorize(id: "r2", credential: foreign.id, ref: rig.gestureRef()))
        rig.router.handle(.credentialsRemove(id: "r3", credential: foreign.id))
        await rig.settle()
        for id in ["r1", "r2", "r3"] { #expect(rejection(rig.reply(id))?.hasPrefix("unknownCredential") == true) }
        #expect(rig.fetcher.urls.isEmpty)
        #expect(rig.grants.grants(pluginID: "studio.other.plugin") == [foreign])
    }

    @Test func aCredentialFetchResolvesWithoutUIAndHandsTheFetcherTheCredential() async throws {
        let rig = CredentialRig()
        let grant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .codex, path: "/Users/evan/.codex"))
        rig.fetcher.enqueue(.success(LeoPluginFetchResponse(status: 200, headers: [:], body: "{}")))
        rig.router.handle(.fetch(id: "r1", url: "https://chatgpt.com/backend-api/wham/usage", init: LeoPluginFetchInit(credential: grant.id)))
        await rig.settle()
        #expect(rig.resolver.calls.map(\.allowUI) == [false])
        #expect(rig.fetcher.credentials == [LeoPluginFetchCredential(boundHost: "chatgpt.com", headers: ["Authorization": "Bearer t"])])
        if case .value? = rig.reply("r1") {} else { Issue.record("expected a value reply") }
    }

    @Test func aBackgroundFetchThatWouldNeedUIIsRejectedWithoutPrompting() async throws {
        let rig = CredentialRig()
        let grant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .claudeCode, path: "/Users/evan/.claude"))
        rig.resolver.failure = .needsAuthorization
        rig.router.handle(.fetch(id: "r1", url: "https://api.anthropic.com/api/oauth/usage", init: LeoPluginFetchInit(credential: grant.id)))
        await rig.settle()
        #expect(rejection(rig.reply("r1"))?.hasPrefix("credentialNeedsAuthorization") == true)
        #expect(rig.resolver.calls.map(\.allowUI) == [false])
        #expect(rig.fetcher.urls.isEmpty)
    }

    @Test func authorizeRetriesWithUIOnAGesture() async throws {
        let rig = CredentialRig()
        let grant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .claudeCode, path: "/Users/evan/.claude"))
        rig.router.handle(.credentialsAuthorize(id: "r1", credential: grant.id, ref: nil))
        rig.router.handle(.credentialsAuthorize(id: "r2", credential: grant.id, ref: rig.gestureRef()))
        await rig.settle()
        #expect(rejection(rig.reply("r1"))?.hasPrefix("gestureRequired") == true)
        #expect(rig.reply("r2") == .value(.null))
        #expect(rig.resolver.calls.map(\.allowUI) == [true])
    }

    @Test func removeDropsTheGrant() async throws {
        let rig = CredentialRig()
        let grant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .codex, path: "/Users/evan/.codex"))
        rig.router.handle(.credentialsRemove(id: "r1", credential: grant.id))
        #expect(rig.reply("r1") == .value(.null))
        #expect(rig.grants.grants(pluginID: usageID).isEmpty)
    }

    @Test func aPaletteCommandCarriesAGestureRefThatCanPromptButNotFollowUp() async {
        let rig = CredentialRig()
        let event = rig.router.commandEvent(id: "add-codex", slot: nil, gesture: LeoPluginGesture(origin: .keyboard, mintedAt: Date(timeIntervalSince1970: 1_000)))
        guard case .command("add-codex", nil, let ref?) = event else { Issue.record("expected a command with a ref"); return }
        rig.router.handle(.callbackResult(ref: ref, action: .copy("x")))
        #expect(rig.actions.performed.isEmpty)
        rig.router.handle(.credentialsAdd(id: "r1", kind: "codex", ref: ref))
        await rig.settle()
        #expect(rig.picker.asked == [.codex])
    }

    @Test func aCredentialFetchTheFetcherRefusesNeverReadsTheAccount() async throws {
        let engine = LeoPluginPermissionEngine(permissions: manifest().permissions)
        let overRate = LeoPluginRateLimiter(maxPerWindow: 1, now: { 0 })
        _ = overRate.acquire()  // spend the window's only request
        for (url, limiter) in [("https://chatgpt.com:bad/x", LeoPluginRateLimiter()), ("https://chatgpt.com/x", overRate)] {
            let rig = CredentialRig(fetching: LeoPluginFetcher(pluginID: usageID, engine: engine, limiter: limiter))
            let grant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .codex, path: "/Users/evan/.codex"))
            rig.router.handle(.fetch(id: "r1", url: url, init: LeoPluginFetchInit(credential: grant.id)))
            for _ in 0..<200 where rig.reply("r1") == nil { await Task.yield() }
            #expect(rejection(rig.reply("r1")) != nil)
            #expect(rig.resolver.calls.isEmpty)
        }
    }
}

// MARK: Accounts on another machine

private let dionysusHost = LeoHostID.remote("Dionysus")

private actor DionysusTransport: LeoDaemonTransport {
    private(set) var requests: [LeoHTTPRequest] = []
    private let replies: [String: String]
    init(_ replies: [String: String]) { self.replies = replies }

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        requests.append(request)
        return LeoHTTPResponse(status: 200, body: Data((replies[request.path] ?? "{}").utf8))
    }

    var paths: [String] { requests.map(\.path) }
}

@MainActor private final class DionysusForwarding: LeoPluginRemoteCredentialForwarding {
    let transport: DionysusTransport
    private(set) var asked: [LeoHostID] = []
    init(_ replies: [String: String]) { transport = DionysusTransport(replies) }

    func daemon(for host: LeoHostID) -> (any LeoDaemonClient)? {
        asked.append(host)
        return LeoSocketDaemonClient(socketPath: "/tmp/dionysus.sock", transport: transport)
    }
}

private let claudeOnDionysus = "/Users/evan/.claude-blackpaw-leo"

extension LeoPluginBridgeRouterTests {
    @Test func addingARemoteAccountChecksItOnThatMachineAndNeverOnThisMac() async throws {
        let remote = DionysusForwarding(["/credentials/check": #"{"ok":true}"#])
        let rig = CredentialRig(pickerAnswer: claudeOnDionysus, remote: remote)
        rig.picker.machine = dionysusHost
        rig.router.handle(.credentialsAdd(id: "r1", kind: "claude-code", ref: rig.gestureRef()))
        await rig.settle()

        #expect(rig.reply("r1") == .value(.object([
            "id": .string("grant-1"), "kind": .string("claude-code"), "label": .string(".claude-blackpaw-leo"),
            "path": .string(claudeOnDionysus), "machine": .string("Dionysus"),
        ])))
        #expect(rig.resolver.calls.isEmpty)
        #expect(await remote.transport.paths == ["/credentials/check"])
        #expect(rig.grants.grants(pluginID: usageID).map(\.machine) == [dionysusHost])
    }

    @Test func aRemoteAccountTheMachineWontActAsIsNotGranted() async {
        let remote = DionysusForwarding(["/credentials/check": #"{"error":{"reason":"credentialInvalid","message":"no sign-in found"}}"#])
        let rig = CredentialRig(pickerAnswer: claudeOnDionysus, remote: remote)
        rig.picker.machine = dionysusHost
        rig.router.handle(.credentialsAdd(id: "r1", kind: "claude-code", ref: rig.gestureRef()))
        await rig.settle()
        #expect(rejection(rig.reply("r1")) == "credentialInvalid: no sign-in found")
        #expect(rig.grants.grants(pluginID: usageID).isEmpty)
    }

    @Test func aRemoteAccountOnAMachineThatIsNotConnectedIsOffline() async {
        let rig = CredentialRig(pickerAnswer: claudeOnDionysus, remote: nil)
        rig.picker.machine = dionysusHost
        rig.router.handle(.credentialsAdd(id: "r1", kind: "claude-code", ref: rig.gestureRef()))
        await rig.settle()
        #expect(rejection(rig.reply("r1")) == "credentialMachineUnavailable: Dionysus is offline")
        #expect(rig.grants.grants(pluginID: usageID).isEmpty)
    }

    @Test func aRemotePathMustBeAbsolute() async {
        let remote = DionysusForwarding(["/credentials/check": #"{"ok":true}"#])
        let rig = CredentialRig(pickerAnswer: "~/.claude", remote: remote)
        rig.picker.machine = dionysusHost
        rig.router.handle(.credentialsAdd(id: "r1", kind: "claude-code", ref: rig.gestureRef()))
        await rig.settle()
        #expect(rejection(rig.reply("r1")) != nil)
        #expect(rig.grants.grants(pluginID: usageID).isEmpty)
    }

    @Test func aRemoteGrantsFetchGoesToItsMachineAndLocalGrantsNeverTouchTheForwarder() async throws {
        let engine = LeoPluginPermissionEngine(permissions: manifest().permissions)
        let reply = #"{"status":200,"headers":[],"bodyBase64":"\#(Data("{}".utf8).base64EncodedString())"}"#
        let remote = DionysusForwarding(["/credentials/fetch": reply])
        let rig = CredentialRig(fetching: LeoPluginFetcher(pluginID: usageID, engine: engine), remote: remote)
        let remoteGrant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .claudeCode, path: claudeOnDionysus, machine: dionysusHost))

        rig.router.handle(.fetch(id: "r1", url: "https://api.anthropic.com/api/oauth/usage", init: LeoPluginFetchInit(credential: remoteGrant.id)))
        for _ in 0..<200 where rig.reply("r1") == nil { await Task.yield() }
        guard case .value? = rig.reply("r1") else {
            Issue.record("expected a value, got \(String(describing: rig.reply("r1")))")
            return
        }
        #expect(rig.resolver.calls.isEmpty)
        #expect(await remote.transport.paths == ["/credentials/fetch"])
        #expect(remote.asked == [dionysusHost])
    }

    @Test func aLocalGrantsFetchReadsItsTokenHereAndNeverTouchesTheForwarder() async throws {
        let remote = DionysusForwarding([:])
        let rig = CredentialRig(remote: remote)
        rig.fetcher.enqueue(.success(LeoPluginFetchResponse(status: 200, headers: [:], body: "{}")))
        let grant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .claudeCode, path: "/Users/evan/.claude"))
        rig.router.handle(.fetch(id: "r1", url: "https://api.anthropic.com/x", init: LeoPluginFetchInit(credential: grant.id)))
        for _ in 0..<200 where rig.reply("r1") == nil { await Task.yield() }
        #expect(rig.reply("r1") != nil)
        #expect(rig.resolver.calls.map(\.path) == ["/Users/evan/.claude"])
        #expect(remote.asked.isEmpty)
        #expect(await remote.transport.requests.isEmpty)
    }

    @Test func aRemoteFetchThatFailsACheckIsNeverForwarded() async throws {
        let engine = LeoPluginPermissionEngine(permissions: manifest().permissions)
        let remote = DionysusForwarding(["/credentials/fetch": #"{"status":200,"headers":[]}"#])
        let rig = CredentialRig(fetching: LeoPluginFetcher(pluginID: usageID, engine: engine), remote: remote)
        let grant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .claudeCode, path: claudeOnDionysus, machine: dionysusHost))
        let cases: [(String, LeoPluginFetchInit)] = [
            ("https://chatgpt.com/x", LeoPluginFetchInit(credential: grant.id)),
            ("https://api.anthropic.com/x", LeoPluginFetchInit(headers: ["User-Agent": "mine"], credential: grant.id)),
            ("http://api.anthropic.com/x", LeoPluginFetchInit(credential: grant.id)),
        ]
        for (index, (url, options)) in cases.enumerated() {
            rig.router.handle(.fetch(id: "r\(index)", url: url, init: options))
            for _ in 0..<200 where rig.reply("r\(index)") == nil { await Task.yield() }
            #expect(rejection(rig.reply("r\(index)")) != nil)
        }
        #expect(await remote.transport.requests.isEmpty)
        #expect(rig.resolver.calls.isEmpty)
    }

    @Test func authorizingARemoteGrantAsksItsMachineWithoutTouchingThisMacsKeychain() async throws {
        let remote = DionysusForwarding(["/credentials/check": #"{"ok":true}"#])
        let rig = CredentialRig(remote: remote)
        let grant = try #require(try rig.grants.addGrant(pluginID: usageID, kind: .claudeCode, path: claudeOnDionysus, machine: dionysusHost))
        rig.router.handle(.credentialsAuthorize(id: "r1", credential: grant.id, ref: rig.gestureRef()))
        await rig.settle()
        #expect(rig.reply("r1") == .value(.null))
        #expect(rig.resolver.calls.isEmpty)
        #expect(await remote.transport.paths == ["/credentials/check"])
    }

    @Test func listShowsAMachineOnlyForRemoteAccounts() async throws {
        let rig = CredentialRig()
        _ = try rig.grants.addGrant(pluginID: usageID, kind: .codex, path: "/Users/evan/.codex")
        _ = try rig.grants.addGrant(pluginID: usageID, kind: .codex, path: "/Users/evan/.codex", machine: dionysusHost)
        rig.router.handle(.credentialsList(id: "r1"))
        guard case .value(.array(let handles))? = rig.reply("r1") else {
            Issue.record("expected handles")
            return
        }
        let machines = handles.map { handle -> String? in
            guard case .object(let fields) = handle, case .string(let name)? = fields["machine"] else { return nil }
            return name
        }
        #expect(machines == [nil, "Dionysus"])
    }
}
