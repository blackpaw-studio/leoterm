import Foundation
import Testing

@testable import LeoKit

private let agent = LeoPluginAgentRef(machine: "localhost", name: "alpha")

private func sampleRoot() throws -> LeoPluginSlotRoot {
    try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))])
}

@MainActor private final class Rig {
    let slots = LeoPluginSlotStore()
    let actions = PluginFakeActions()
    let fetcher = PluginFakeFetcher()
    let keychain = PluginFakeKeychain()
    let scheduler = PluginManualScheduler()
    var sent: [LeoPluginEvent] = []
    var now = Date(timeIntervalSince1970: 1_000)
    var fired: [String] = []
    let router: LeoPluginBridgeRouter
    let timers: LeoPluginTimers
    var agents: [(LeoHostID, LeoAgent)] {
        get { box.agents }
        set { box.agents = newValue }
    }
    var readings: [LeoPluginAgentRef: LeoPluginUsageReading] {
        get { box.readings }
        set { box.readings = newValue }
    }

    init(permissions: LeoPluginPermissions = LeoPluginPermissions(network: ["api.example.com"], secrets: true, agents: [.read, .send, .spawn])) {
        let manifest = LeoPluginManifest(
            id: "studio.blackpaw.demo", name: "Demo", version: "1.0.0", apiVersion: 1, main: "main.js", permissions: permissions,
            contributes: LeoPluginContributions(
                views: [LeoPluginViewContribution(id: "main", title: "Main", sfSymbol: "star")],
                rowAccessories: [LeoPluginRowAccessoryContribution(id: "pr")],
                commands: [LeoPluginCommandContribution(id: "go", title: "Go")],
                sidebarSections: [LeoPluginSidebarSectionContribution(id: "issues", title: "Issues")],
                panes: [LeoPluginPaneContribution(id: "status", title: "Status")]))
        let engine = LeoPluginPermissionEngine(permissions: permissions)
        timers = LeoPluginTimers(scheduler: scheduler, onFire: { _ in })
        let box = Box()
        let gate = LeoPluginActionGate(grants: permissions, now: { box.now })
        let rigSlots = slots
        let rigActions = actions
        let rigFetcher = fetcher
        let secrets = try? LeoPluginSecrets(pluginID: manifest.id, engine: engine, keychain: keychain)
        let sink = Sink()
        router = LeoPluginBridgeRouter(
            LeoPluginBridgeRouter.Dependencies(
                identity: LeoPluginIdentity(id: manifest.id, name: manifest.name), manifest: manifest, engine: engine, gate: gate,
                fetcher: rigFetcher, secrets: secrets, timers: timers, slots: rigSlots, actions: rigActions,
                agents: { box.agents }, now: { box.now }, send: { sink.events.append($0) },
                usage: { box.readings[$0] }, homeDirectory: "/Users/evan"))
        self.box = box
        self.sink = sink
    }

    private let box: Box
    private let sink: Sink
    var events: [LeoPluginEvent] { sink.events }
    func setNow(_ date: Date) { box.now = date }

    final class Box: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        var agents: [(LeoHostID, LeoAgent)] = []
        var readings: [LeoPluginAgentRef: LeoPluginUsageReading] = [:]
    }
    @MainActor final class Sink { var events: [LeoPluginEvent] = [] }

    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    var slotKey: LeoPluginSlotKey { LeoPluginSlotKey(pluginID: "studio.blackpaw.demo", slot: .section(id: "issues")) }
}

@MainActor struct LeoPluginBridgeRouterTests {
    @Test func aRenderForADeclaredSlotReachesTheStore() throws {
        let rig = Rig()
        rig.router.handle(.render(slot: .section(id: "issues"), node: try sampleRoot()))
        #expect(rig.slots.state(rig.slotKey) == .tree(try sampleRoot()))
    }

    @Test func aRenderForAnUndeclaredContributionIsRefused() throws {
        let rig = Rig()
        for slot in [LeoPluginSlotID.section(id: "nope"), .view(viewID: "nope", agent: agent), .accessory(id: "nope", agent: agent), .palette(commandID: "nope"),
            .pane(id: "nope", part: .summary, agent: agent), .pane(id: "nope", part: .body, agent: agent),
        ] {
            rig.router.handle(.render(slot: slot, node: try sampleRoot()))
            #expect(rig.slots.state(pluginID: "studio.blackpaw.demo", slot: slot) == .loading)
        }
        #expect(rig.slots.slots(of: "studio.blackpaw.demo").isEmpty)
    }

    @Test func aRenderForADeclaredPaneReachesTheStore() throws {
        let rig = Rig()
        let slot = LeoPluginSlotID.pane(id: "status", part: .body, agent: agent)
        rig.router.handle(.render(slot: slot, node: try sampleRoot()))
        #expect(rig.slots.state(pluginID: "studio.blackpaw.demo", slot: slot) == .tree(try sampleRoot()))
    }

    @Test func aPaneSummaryAcceptsOnlyTextMeterAndAccessory() throws {
        let rig = Rig()
        let summary = LeoPluginSlotID.pane(id: "status", part: .summary, agent: agent)
        let allowed = try LeoPluginSlotRoot(nodes: [
            .meter(.init(segments: [.init(value: 1, tone: .success)], max: 2)),
            .text(.init(runs: [.init(text: "62%")])),
            .accessory(.init(text: "ok")),
        ])
        rig.router.handle(.render(slot: summary, node: allowed))
        #expect(rig.slots.state(pluginID: "studio.blackpaw.demo", slot: summary) == .tree(allowed))

        let forbidden: [LeoPluginNode] = [
            .list(.init(sections: [])), .detail(.init(markdown: "x")), .form(.init(id: "f", fields: [])),
            .emptyState(.init(title: "x")), .loading(.init(message: nil)),
            .error(.init(message: "x", retry: .callback(id: "r", payload: .null))),
        ]
        for node in forbidden {
            // Mixed with allowed nodes, a single bad one still fails the slot.
            rig.router.handle(.render(slot: summary, node: try LeoPluginSlotRoot(nodes: [.text(.init(runs: [.init(text: "a")])), node])))
            guard case .error(let message) = rig.slots.state(pluginID: "studio.blackpaw.demo", slot: summary) else {
                Issue.record("expected an error for \(node)")
                continue
            }
            #expect(message.contains("Text, Meter and Accessory"))
        }
    }

    @Test func aPaneSummaryRecoversOnTheNextAllowedRenderAndTheBodyAcceptsAnyComponent() throws {
        let rig = Rig()
        let summary = LeoPluginSlotID.pane(id: "status", part: .summary, agent: agent)
        let body = LeoPluginSlotID.pane(id: "status", part: .body, agent: agent)
        let list = try LeoPluginSlotRoot(nodes: [.list(.init(sections: []))])
        rig.router.handle(.render(slot: summary, node: list))
        rig.router.handle(.render(slot: body, node: list))
        #expect(rig.slots.state(pluginID: "studio.blackpaw.demo", slot: body) == .tree(list))

        let text = try LeoPluginSlotRoot(nodes: [.text(.init(runs: [.init(text: "ok")]))])
        rig.router.handle(.render(slot: summary, node: text))
        #expect(rig.slots.state(pluginID: "studio.blackpaw.demo", slot: summary) == .tree(text))
    }

    @Test func otherSlotKindsStillAcceptAnyComponent() throws {
        let rig = Rig()
        let list = try LeoPluginSlotRoot(nodes: [.list(.init(sections: []))])
        rig.router.handle(.render(slot: .section(id: "issues"), node: list))
        #expect(rig.slots.state(rig.slotKey) == .tree(list))
    }

    @Test func fetchRepliesWithTheResponseValueAndItsBodyEncoding() async throws {
        let rig = Rig()
        let response = LeoPluginFetchResponse(status: 200, headers: ["etag": "x"], body: "AAEC", bodyEncoding: .base64)
        rig.fetcher.enqueue(.success(response))
        rig.router.handle(.fetch(id: "r1", url: "https://api.example.com/x", init: LeoPluginFetchInit()))
        await rig.settle()
        #expect(rig.events == [.reply(id: "r1", outcome: .value(response.replyValue))])
        guard case .reply(_, .value(.object(let fields)))? = rig.events.first else { Issue.record("no reply"); return }
        #expect(fields["bodyEncoding"] == .string("base64"))
    }

    @Test func aFailedFetchRejectsWithTheReason() async {
        let rig = Rig()
        rig.fetcher.enqueue(.failure(LeoPluginFetchError.denied("host not allowed")))
        rig.router.handle(.fetch(id: "r2", url: "https://evil.example.org/", init: LeoPluginFetchInit()))
        await rig.settle()
        #expect(rig.events == [.reply(id: "r2", outcome: .rejected(reason: "host not allowed"))])
    }

    @Test func aFetchThatCompletesAfterCloseSendsNothing() async throws {
        let rig = Rig()
        rig.fetcher.enqueue(.success(LeoPluginFetchResponse(status: 200, headers: [:], body: "")))
        rig.router.handle(.fetch(id: "r3", url: "https://api.example.com/", init: LeoPluginFetchInit()))
        rig.router.close()
        await rig.settle()
        #expect(rig.events.isEmpty)
        rig.router.handle(.agentsList(id: "r4"))
        #expect(rig.events.isEmpty)
    }

    @Test func secretsRoundTripThroughThePluginsOwnKeychainNamespace() {
        let rig = Rig()
        rig.router.handle(.secretsSet(id: "r1", key: "token", value: "s3cret"))
        rig.router.handle(.secretsGet(id: "r2", key: "token"))
        rig.router.handle(.secretsGet(id: "r3", key: "missing"))
        rig.router.handle(.secretsDelete(id: "r4", key: "token"))
        rig.router.handle(.secretsGet(id: "r5", key: "token"))
        #expect(rig.events == [
            .reply(id: "r1", outcome: .value(.null)), .reply(id: "r2", outcome: .value(.string("s3cret"))),
            .reply(id: "r3", outcome: .value(.null)), .reply(id: "r4", outcome: .value(.null)),
            .reply(id: "r5", outcome: .value(.null)),
        ])
    }

    @Test func secretsWithoutThePermissionAreRejected() {
        let rig = Rig(permissions: .none)
        rig.router.handle(.secretsGet(id: "r1", key: "token"))
        guard case .reply(_, .rejected(let reason))? = rig.events.first else { Issue.record("expected rejection"); return }
        #expect(reason.contains("secrets"))
    }

    @Test func agentsListNeedsReadAndCarriesNoPaths() {
        let rig = Rig()
        rig.agents = [(.local, LeoAgent(name: "alpha", repo: "x/y", workspace: "/secret/path", branch: "b", canonicalPath: "/secret/canon", status: .running))]
        rig.router.handle(.agentsList(id: "r1"))
        guard case .reply(_, .value(.array(let entries)))? = rig.events.first, case .object(let fields)? = entries.first else {
            Issue.record("expected an agents array"); return
        }
        #expect(fields["name"] == .string("alpha"))
        #expect(!fields.keys.contains { $0.lowercased().contains("path") || $0 == "workspace" })

        let denied = Rig(permissions: .none)
        denied.router.handle(.agentsList(id: "r2"))
        guard case .reply(_, .rejected)? = denied.events.first else { Issue.record("expected rejection"); return }
    }

    // MARK: agents.usage

    private func usageRig(_ verbs: [LeoPluginAgentVerb]) -> Rig {
        let rig = Rig(permissions: LeoPluginPermissions(agents: verbs))
        rig.readings[agent] = LeoPluginUsageReading(
            configuredModel: "configured",
            usage: LeoAgentUsage(session: LeoUsageTotals(tokens: 5, costUSD: 1.5), model: "observed"), harnessReportsUsage: true)
        return rig
    }

    @Test func agentsUsageRepliesWithTheSnapshotWhenUsageIsGranted() {
        let rig = usageRig([.usage])
        rig.router.handle(.agentsUsage(id: "u1", agent: agent))
        #expect(rig.events == [.reply(id: "u1", outcome: .value(.object([
            "model": .string("observed"), "session": .object(["tokens": .int(5), "costUsd": .double(1.5)]),
        ])))])
    }

    @Test(arguments: [[LeoPluginAgentVerb](), [.read], [.read, .send, .spawn]])
    func agentsUsageIsRejectedWithoutTheUsagePermissionAndLeaksNothing(_ verbs: [LeoPluginAgentVerb]) {
        let rig = usageRig(verbs)
        rig.router.handle(.agentsUsage(id: "u1", agent: agent))
        guard case .reply(_, .rejected(let reason))? = rig.events.first else { Issue.record("expected rejection"); return }
        #expect(reason.contains("usage"))
        #expect(!reason.contains("observed"))
    }

    @Test func agentsUsageForAnUnknownAgentIsNullAndAfterCloseNothingIsSent() {
        let rig = usageRig([.usage])
        rig.router.handle(.agentsUsage(id: "u1", agent: LeoPluginAgentRef(machine: "elsewhere", name: "ghost")))
        #expect(rig.events == [.reply(id: "u1", outcome: .value(.null))])
        rig.router.close()
        rig.router.handle(.agentsUsage(id: "u2", agent: agent))
        #expect(rig.events.count == 1)
    }

    @Test func agentsListGainsModelAndWorkspaceOnlyBehindUsage() {
        func fields(_ verbs: [LeoPluginAgentVerb]) -> [String: LeoJSONValue] {
            let rig = usageRig(verbs)
            rig.agents = [(.local, LeoAgent(name: "alfred", workspace: "/Users/evan/.leo/agents/alfred", model: "configured"))]
            rig.readings = [LeoPluginAgentRef(machine: "localhost", name: "alfred"): LeoPluginUsageReading(
                configuredModel: "configured", usage: LeoAgentUsage(session: LeoUsageTotals(tokens: 1, costUSD: 1), model: "observed"),
                harnessReportsUsage: true)]
            rig.router.handle(.agentsList(id: "l"))
            guard case .reply(_, .value(.array(let entries)))? = rig.events.first, case .object(let object)? = entries.first else { return [:] }
            return object
        }
        let granted = fields([.read, .usage])
        #expect(granted["workspace"] == .string("~/.leo/agents/alfred"))
        #expect(granted["model"] == .string("observed"))
        let readOnly = fields([.read])
        #expect(readOnly["workspace"] == nil)
        #expect(readOnly["model"] == nil)
    }

    @Test func timersAreBoundedAndStoppable() {
        let rig = Rig()
        rig.router.handle(.timerStart(id: "t1", seconds: 1e19))     // clamped, must not trap
        rig.router.handle(.timerStart(id: "t2", seconds: 5))        // below the minimum
        rig.router.handle(.afterStart(id: "t3", seconds: 2))
        rig.router.handle(.timerStart(id: String(repeating: "x", count: 500), seconds: 60))
        #expect(rig.timers.activeIDs == ["t1", "t3"])
        rig.router.handle(.timerStop(id: "t1"))
        #expect(rig.timers.activeIDs == ["t3"])
    }

    @Test func aHandlerErrorBeforeTheFirstRenderMarksWaitingSlotsFailed() throws {
        let rig = Rig()
        rig.slots.expect(pluginID: "studio.blackpaw.demo", slot: .section(id: "issues"))
        rig.router.handle(.handlerError(source: "activate", message: "TypeError: x"))
        #expect(rig.slots.state(rig.slotKey) == .error("TypeError: x"))
    }

    @Test func unsupportedCallsLikeSendToAgentAreDroppedWithNoEffect() throws {
        let rig = Rig()
        let json = #"{"call":"sendToAgent","agent":{"machine":"localhost","name":"alpha"},"text":"rm -rf"}"#
        rig.router.handle(try LeoPluginFrame.decodeRequest(json))
        #expect(rig.actions.confirmed.isEmpty)
        #expect(rig.actions.performed.isEmpty)
        #expect(rig.events.isEmpty)
    }

    // MARK: Callback follow-ups

    @Test func aFollowUpFromAGestureCallbackReachesTheConfirmationPathOnce() {
        let rig = Rig()
        let event = rig.router.callbackEvent(id: "send", payload: .null, gesture: gestureNow(rig.now), slot: .section(id: "issues"))
        guard case .callback(let ref, _, _, let hasGesture) = event else { Issue.record("not a callback"); return }
        #expect(hasGesture)
        let action = LeoPluginAction.sendToAgent(agent: agent, text: "hi")

        rig.router.handle(.callbackResult(ref: ref, action: action))
        rig.router.handle(.callbackResult(ref: ref, action: action))   // the ref is single-use

        #expect(rig.actions.confirmed.count == 1)
        #expect(rig.actions.confirmed.first?.0 == action)
        #expect(rig.actions.confirmed.first?.1 == LeoPluginIdentity(id: "studio.blackpaw.demo", name: "Demo"))
    }

    @Test func aFollowUpFromACallbackWithoutAGestureIsDropped() {
        let rig = Rig()
        guard case .callback(let ref, _, _, let hasGesture) = rig.router.callbackEvent(id: "x", payload: .null, gesture: nil, slot: nil) else { Issue.record("no callback"); return }
        #expect(!hasGesture)
        rig.router.handle(.callbackResult(ref: ref, action: .sendToAgent(agent: agent, text: "hi")))
        rig.router.handle(.callbackResult(ref: ref, action: .copy("x")))
        #expect(rig.actions.confirmed.isEmpty)
        #expect(rig.actions.performed.isEmpty)
    }

    @Test func aRefThePluginInventedIsDropped() {
        let rig = Rig()
        rig.router.handle(.callbackResult(ref: "made-up", action: .spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "p", machine: nil))))
        #expect(rig.actions.confirmed.isEmpty)
    }

    @Test func aRefFromAnotherSessionOrPluginIsDropped() {
        let one = Rig()
        let two = Rig()
        guard case .callback(let ref, _, _, _) = one.router.callbackEvent(id: "x", payload: .null, gesture: gestureNow(one.now), slot: nil) else { Issue.record("no callback"); return }
        two.router.handle(.callbackResult(ref: ref, action: .sendToAgent(agent: agent, text: "hi")))
        #expect(two.actions.confirmed.isEmpty)
    }

    @Test func aFollowUpAfterTheWindowIsDropped() {
        let rig = Rig()
        guard case .callback(let ref, _, _, _) = rig.router.callbackEvent(id: "x", payload: .null, gesture: gestureNow(rig.now), slot: nil) else { Issue.record("no callback"); return }
        rig.setNow(rig.now.addingTimeInterval(31))
        rig.router.handle(.callbackResult(ref: ref, action: .sendToAgent(agent: agent, text: "hi")))
        #expect(rig.actions.confirmed.isEmpty)
    }

    @Test func aFollowUpNeedsThePermissionEvenWithAGesture() {
        let rig = Rig(permissions: LeoPluginPermissions(agents: [.read]))
        guard case .callback(let ref, _, _, _) = rig.router.callbackEvent(id: "x", payload: .null, gesture: gestureNow(rig.now), slot: nil) else { Issue.record("no callback"); return }
        rig.router.handle(.callbackResult(ref: ref, action: .sendToAgent(agent: agent, text: "hi")))
        #expect(rig.actions.confirmed.isEmpty)
    }

    @Test func aGesturedFollowUpPushViewRunsOnTheCallbacksSlot() throws {
        let rig = Rig()
        let slot = LeoPluginSlotID.palette(commandID: "go")
        guard case .callback(let ref, _, _, _) = rig.router.callbackEvent(id: "x", payload: .null, gesture: gestureNow(rig.now), slot: slot) else { Issue.record("no callback"); return }
        let node = LeoPluginNode.loading(.init(message: nil))
        rig.router.handle(.callbackResult(ref: ref, action: .pushView(node: node)))
        #expect(rig.actions.performed.count == 1)
        #expect(rig.actions.performed.first?.2 == slot)
    }

    @Test func aCallbackThatResolvesToACallbackIsDropped() {
        let rig = Rig()
        guard case .callback(let ref, _, _, _) = rig.router.callbackEvent(id: "x", payload: .null, gesture: gestureNow(rig.now), slot: nil) else { Issue.record("no callback"); return }
        rig.router.handle(.callbackResult(ref: ref, action: .callback(id: "again", payload: .null)))
        #expect(rig.actions.performed.isEmpty)
        #expect(rig.events.isEmpty)
    }

    @Test func closingDropsLiveCallbackRefs() {
        let rig = Rig()
        guard case .callback(let ref, _, _, _) = rig.router.callbackEvent(id: "x", payload: .null, gesture: gestureNow(rig.now), slot: nil) else { Issue.record("no callback"); return }
        rig.router.close()
        rig.router.handle(.callbackResult(ref: ref, action: .sendToAgent(agent: agent, text: "hi")))
        #expect(rig.actions.confirmed.isEmpty)
    }
}

@MainActor struct LeoPluginSlotStoreTests {
    private let id = "studio.blackpaw.demo"

    @Test func everySlotStartsAsLoadingAndAPluginStatusOverridesAllItsSlots() throws {
        let store = LeoPluginSlotStore()
        let a = LeoPluginSlotKey(pluginID: id, slot: .section(id: "a"))
        let b = LeoPluginSlotKey(pluginID: id, slot: .view(viewID: "v", agent: agent))
        #expect(store.state(a) == .loading)
        store.render(pluginID: id, slot: a.slot, root: try sampleRoot())
        #expect(store.state(a) == .tree(try sampleRoot()))

        store.setStatus(pluginID: id, .failed(reason: "crashed"))
        #expect(store.state(a) == .error("crashed"))
        #expect(store.state(b) == .error("crashed"))
        store.setStatus(pluginID: id, .disabled(reason: "off"))
        #expect(store.state(b) == .disabled("off"))
        store.setStatus(pluginID: id, .running)
        #expect(store.state(a) == .tree(try sampleRoot()))
        store.reset(pluginID: id)
        #expect(store.state(a) == .loading)
    }

    @Test func aPluginCantRenderMoreSlotsThanTheCap() throws {
        let store = LeoPluginSlotStore()
        for index in 0..<LeoPluginSlotStore.maxSlotsPerPlugin {
            #expect(store.render(pluginID: id, slot: .accessory(id: "pr", agent: LeoPluginAgentRef(machine: "m", name: "a\(index)")), root: try sampleRoot()))
        }
        #expect(!store.render(pluginID: id, slot: .accessory(id: "pr", agent: LeoPluginAgentRef(machine: "m", name: "extra")), root: try sampleRoot()))
        // An existing slot can still update.
        #expect(store.render(pluginID: id, slot: .accessory(id: "pr", agent: LeoPluginAgentRef(machine: "m", name: "a0")), root: try sampleRoot()))
    }

    @Test func pushedViewsStackAndPop() {
        let store = LeoPluginSlotStore()
        let key = LeoPluginSlotKey(pluginID: id, slot: .palette(commandID: "go"))
        store.push(.loading(.init(message: nil)), onto: key)
        store.push(.loading(.init(message: "x")), onto: key)
        #expect(store.pushed[key]?.count == 2)
        store.pop(key)
        store.pop(key)
        #expect(store.pushed[key] == nil)
    }
}
