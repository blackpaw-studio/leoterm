import Foundation
import Testing

@testable import LeoKit

private let usageID = "studio.blackpaw.usage"

@MainActor private final class FakePicker: LeoPluginCredentialPicking {
    var answer: String?
    private(set) var asked: [LeoPluginCredentialKind] = []
    init(answer: String?) { self.answer = answer }
    func pickFolder(for kind: LeoPluginCredentialKind) async -> String? {
        asked.append(kind)
        return answer
    }
}

private final class FakeResolver: LeoPluginCredentialResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, Bool)] = []
    var failure: LeoPluginCredentialError?
    var calls: [(path: String, allowUI: Bool)] { lock.withLock { _calls.map { (path: $0.0, allowUI: $0.1) } } }

    func resolve(_ grant: LeoPluginCredentialGrant, allowUI: Bool) throws(LeoPluginCredentialError) -> LeoPluginFetchCredential {
        let failure = lock.withLock { () -> LeoPluginCredentialError? in
            _calls.append((grant.path, allowUI))
            return self.failure
        }
        if let failure { throw failure }
        return LeoPluginFetchCredential(boundHost: grant.kind.boundHost, headers: ["Authorization": "Bearer t"])
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

    func addGrant(pluginID: String, kind: LeoPluginCredentialKind, path: String) throws -> LeoPluginCredentialGrant? {
        lock.withLock {
            counter += 1
            return registry.addGrant(pluginID: pluginID, kind: kind, path: path, id: "grant-\(counter)")
        }
    }

    func removeGrant(pluginID: String, grantID: String) throws {
        lock.withLock { registry.removeGrant(pluginID: pluginID, grantID: grantID) }
    }
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

    init(manifest: LeoPluginManifest = manifest(), pickerAnswer: String? = "/Users/evan/.codex") {
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
                gate: LeoPluginActionGate(grants: permissions, now: { box.now }), fetcher: fetcher, secrets: nil,
                timers: LeoPluginTimers(scheduler: scheduler, onFire: { _ in }), slots: LeoPluginSlotStore(), actions: actions,
                agents: { [] }, now: { box.now }, send: { sink.events.append($0) },
                credentials: LeoPluginCredentialServices(picker: picker, resolver: resolver, grants: grants, home: "/Users/evan")))
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
}
