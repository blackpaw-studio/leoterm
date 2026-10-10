#if DEBUG
import Foundation
import Testing

@testable import Ghostty

/// The DEBUG-only `LEO_ATTENTION_FIXTURE` overlay used to screenshot
/// attention badges before the daemon emits `attention`.
struct LeoAttentionFixtureTests {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/attention_overlay.json").path
    }

    @Test func loadsTheOverlayNamedByTheEnvironment() throws {
        let overlay = try #require(LeoAttentionFixture.load(environment: [LeoAttentionFixture.environmentKey: fixturePath]))
        #expect(overlay["alpha"] == LeoAttentionSignal(state: .needsInput, revision: 1))
        #expect(overlay.count == 4)
    }

    /// B-257: a reserved `dispatches` key adds dispatches to `/state`, so
    /// nested rows can be screenshotted; the other keys stay attention.
    @Test func aDispatchesKeyOverlaysDispatchesOnState() async throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dispatch_overlay.json").path
        let file = try #require(LeoAttentionFixture.loadFile(environment: [LeoAttentionFixture.environmentKey: path]))
        #expect(file.attention == ["autopilot-scratch": LeoAttentionSignal(state: .working, revision: 1)])
        #expect(file.dispatches.map(\.id) == ["fx-1", "fx-2", "fx-3"])

        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, observedState: {
            LeoObservedState(agents: [], dispatches: [LeoDispatch(id: "real", status: "running"), LeoDispatch(id: "fx-1", status: "queued")])
        })
        let state = try await LeoAttentionFixture.wrap(base, overlay: file.attention, dispatches: file.dispatches).fetchState()
        #expect(state.dispatches.map(\.id) == ["real", "fx-1", "fx-2", "fx-3"])
        #expect(state.dispatches.first { $0.id == "fx-1" }?.status == "running", "the fixture's record wins")
    }

    /// B-259: reserved `usage` and `turns` keys overlay usage on `/state`
    /// and replay turns; a malformed key degrades to none.
    @Test func usageAndTurnsKeysDecodeAndOverlay() async throws {
        let json = #"{"alpha":{"state":"working","revision":1},"#
            + #""usage":{"alpha":{"session":{"tokens":1200,"cost_usd":0.42}},"beta":{"session":"bad"}},"#
            + #""turns":{"alpha":{"preview":"All done","outcome":"aborted"}}}"#
        let file = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(json.utf8))
        #expect(file.attention.keys.sorted() == ["alpha"])
        #expect(file.usage.keys.sorted() == ["alpha"], "a malformed entry is dropped")
        #expect(file.turns["alpha"]?.preview == "All done" && file.turns["alpha"]?.outcome == .aborted)

        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: {
            [LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil)]
        })
        let state = try await LeoAttentionFixture.wrap(base, overlay: file.attention, usage: file.usage, turns: file.turns).fetchState()
        #expect(state.agents.first?.usage?.session.tokens == 1200)

        let malformed = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(#"{"usage":3,"turns":"x"}"#.utf8))
        #expect(malformed.usage.isEmpty && malformed.turns.isEmpty)
    }

    /// B-260: a reserved `actions` key overlays `current_action` for named
    /// agents only; a malformed entry is dropped and the fixture still loads.
    @Test func actionsKeyOverlaysCurrentAction() async throws {
        let json = #"{"alpha":{"state":"working","revision":1},"#
            + #""actions":{"alpha":{"kind":"tool","detail":"Bash make"},"beta":"bad"}}"#
        let file = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(json.utf8))
        #expect(file.attention.keys.sorted() == ["alpha"])
        #expect(file.actions.keys.sorted() == ["alpha"])

        let pane = LeoCurrentAction(kind: "pane", detail: "Reading")
        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: {
            [
                LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: pane, lastActivityAt: nil),
                LeoObservedAgent(name: "beta", status: .running, activity: .idle, currentAction: pane, lastActivityAt: nil)
            ]
        })
        let state = try await LeoAttentionFixture.wrap(base, overlay: file.attention, actions: file.actions).fetchState()
        #expect(state.agents.first { $0.name == "alpha" }?.currentAction == LeoCurrentAction(kind: "tool", detail: "Bash make"))
        #expect(state.agents.first { $0.name == "beta" }?.currentAction == pane)

        let malformed = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(#"{"actions":3}"#.utf8))
        #expect(malformed.actions.isEmpty)
    }

    @Test func fixtureCompactionsKeyDecodesLeniently() throws {
        let json = #"{"compactions":{"alpha":[{"phase":"started","trigger":"auto"},{"phase":"sideways"},{"phase":"completed"}],"beta":3}}"#
        let file = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(json.utf8))
        #expect(file.compactions == ["alpha": [
            LeoCompactionEvent(agent: "alpha", phase: .started, trigger: .auto, contextPercent: nil),
            LeoCompactionEvent(agent: "alpha", phase: .completed, trigger: nil, contextPercent: nil)
        ]])
        let malformed = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(#"{"compactions":3}"#.utf8))
        #expect(malformed.compactions.isEmpty)
    }

    @Test func controlKeyDecodesLeniently() throws {
        let deny = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(#"{"control":"deny"}"#.utf8))
        #expect(deny.control == .deny)
        let bad = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(#"{"control":"sideways"}"#.utf8))
        #expect(bad.control == nil)
        let malformed = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(#"{"control":3}"#.utf8))
        #expect(malformed.control == nil)
    }

    @Test(arguments: [(LeoControlFixtureMode.deny, "forbidden"), (.unavailable, "unavailable")])
    func controlFixtureAnswersControlRoutesLocallyAndPassesTheRest(mode: LeoControlFixtureMode, code: String) async throws {
        let base = ControlFixtureRecordingTransport()
        let client = LeoSocketDaemonClient(socketPath: "/tmp/leo.sock", transport: LeoControlFixtureTransport(base: base, mode: mode))
        do {
            try await client.interrupt("alpha")
            Issue.record("the control route should have been refused")
        } catch let LeoDaemonError.daemon(actual, _, _) {
            #expect(actual == code)
        }
        _ = try await client.listAgents()
        #expect(await base.paths == ["/agents/list"])
    }

    @Test func helloAdvertisesAgentControlForTheControlFixture() async throws {
        let (stream, continuation) = AsyncStream<LeoObserveEvent>.makeStream()
        continuation.yield(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "b", features: []))
        continuation.finish()
        var seen: [LeoObserveEvent] = []
        for await event in LeoAttentionFixture.advertising(stream, usage: false, turns: [:], control: true) { seen.append(event) }
        guard case .hello(_, _, _, _, _, let features) = seen.first else { Issue.record("no hello"); return }
        #expect(features == ["agent_control"])
    }

    /// B-275: fixture dispatches only show with `dispatch_tree`, so a fixture
    /// that lists them advertises it (D-396).
    @Test(arguments: [(true, ["dispatch_tree"]), (false, [])])
    func aDispatchesKeyAdvertisesDispatchTree(hasDispatches: Bool, expected: [String]) async throws {
        let (stream, continuation) = AsyncStream<LeoObserveEvent>.makeStream()
        continuation.yield(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "b", features: []))
        continuation.finish()
        var seen: [LeoObserveEvent] = []
        for await event in LeoAttentionFixture.advertising(stream, usage: false, turns: [:], dispatchTree: hasDispatches) { seen.append(event) }
        guard case .hello(_, _, _, _, _, let features) = seen.first else { Issue.record("no hello"); return }
        #expect(features == expected)
    }

    @Test func helloAdvertisesTheFixturesFeatures() async throws {
        let (stream, continuation) = AsyncStream<LeoObserveEvent>.makeStream()
        continuation.yield(.hello(seq: 1, at: nil, version: "1", serverTime: nil, bootID: "b", features: ["dispatch_tree"]))
        continuation.finish()
        let turn = LeoTurnCompletion(agent: "alpha", outcome: .completed, preview: "Hi")
        var seen: [LeoObserveEvent] = []
        for await event in LeoAttentionFixture.advertising(stream, usage: true, turns: ["alpha": turn]) { seen.append(event) }
        guard case .hello(_, _, _, _, _, let features) = seen.first else { Issue.record("no hello"); return }
        #expect(features == ["dispatch_tree", "agent_usage", "bridge_turns"])
    }

    @Test func fixtureEntryDecodesItsReason() async throws {
        let json = #"{"alpha":{"state":"needs_input","revision":1,"reason":{"kind":"permission","tool":"Bash"}},"beta":{"state":"needs_input","revision":1}}"#
        let file = try JSONDecoder().decode(LeoAttentionFixture.File.self, from: Data(json.utf8))
        #expect(file.attention["alpha"]?.reason == LeoAttentionReason(kind: .permission, tool: "Bash"))
        #expect(file.attention["beta"]?.reason == nil)
        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, observedState: {
            LeoObservedState(agents: [LeoObservedAgent(name: "alpha", status: nil, activity: nil, currentAction: nil, lastActivityAt: nil, attention: nil)], dispatches: [])
        })
        let state = try await LeoAttentionFixture.wrap(base, overlay: file.attention).fetchState()
        #expect(state.agents.first?.attention?.reason?.tool == "Bash")
    }

    @Test func noEnvironmentOrUnreadableFileMeansNoOverlay() {
        #expect(LeoAttentionFixture.load(environment: [:]) == nil)
        #expect(LeoAttentionFixture.load(environment: [LeoAttentionFixture.environmentKey: "/nonexistent.json"]) == nil)
    }

    @Test func overlayReplacesAttentionOnlyForNamedAgents() async throws {
        let base = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: {
            [
                LeoObservedAgent(name: "alpha", status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil),
                LeoObservedAgent(name: "other", status: .running, activity: .working, currentAction: nil, lastActivityAt: nil)
            ]
        })
        let wrapped = LeoAttentionFixture.wrap(base, overlay: ["alpha": .init(state: .finished, revision: 3)])

        let agents = try await wrapped.fetchState().agents

        #expect(agents.map(\.attention) == [.init(state: .finished, revision: 3), nil])
        #expect(agents.map(\.activity) == [.idle, .working])
    }
}

private actor ControlFixtureRecordingTransport: LeoDaemonTransport {
    private(set) var paths: [String] = []

    func send(_ request: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        paths.append(request.path)
        return LeoHTTPResponse(status: 200, body: Data(#"{"ok":true,"data":[]}"#.utf8))
    }
}
#endif
