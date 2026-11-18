import ComposableArchitecture
import Foundation
import LeoKit
import Testing
@testable import LeoFeatures

/// B-305: Leo for iOS serves the `browser` client-tools group. The app's
/// foreground drives the provider streams, the setting gates them, the
/// pane carries the user's handoff answers, and the agent's detail offers
/// the browser only where it can work.
@MainActor
struct AgentBrowserTests {
    private static let zeus = AgentRef(daemonID: PairedDaemon.dionysus.id, name: "zeus")

    /// What the app asked of the client-tools runtime, in order.
    private final class Calls: Sendable {
        let log = LockIsolated<[String]>([])
        let events = LockIsolated<[LeoBrowserControl.Event]>([])

        var client: ClientToolsClient {
            var client = ClientToolsClient.inert
            let (log, events) = (log, events)
            client.suspend = { log.withValue { $0.append("suspend") } }
            client.resume = { log.withValue { $0.append("resume") } }
            client.setEnabled = { isOn in log.withValue { $0.append("enabled \(isOn)") } }
            client.control = { agent, event in
                log.withValue { $0.append("control \(agent.name)") }
                events.withValue { $0.append(event) }
            }
            return client
        }
    }

    // MARK: - App lifecycle and setting

    @Test func backgroundSuspendsAndActiveResumes() async {
        let calls = Calls()
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.clientTools = calls.client
            $0.pushClient = .granted
            $0.pushCleanup = .inMemory(LockIsolated([:]))
        }
        store.exhaustivity = .off

        await store.send(.scenePhaseChanged(isActive: true))
        await store.send(.scenePhaseChanged(isActive: false))
        await store.finish()

        #expect(calls.log.value == ["resume", "suspend"])
    }

    @Test func settingOffStopsTheBrowserAndOnStartsIt() async {
        let calls = Calls()
        let store = TestStore(initialState: AppFeature.State()) { AppFeature() } withDependencies: {
            $0.clientTools = calls.client
        }

        await store.send(.agentBrowserToggled(false)) { $0.$isAgentBrowserEnabled.withLock { $0 = false } }
        await store.send(.agentBrowserToggled(true)) { $0.$isAgentBrowserEnabled.withLock { $0 = true } }
        await store.finish()

        #expect(calls.log.value == ["enabled false", "enabled true"])
    }

    @Test func turningTheSettingOffClosesAnOpenBrowserPane() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].agents = [Agent(name: "zeus")]
        initial.fleet.sessions[0].features = LeoDaemonFeatures(["client_tools"])
        // The fleet's session isn't connected, so the detail reads offline.
        var detail = AgentDetail.State(daemon: .dionysus, agent: Agent(name: "zeus"), connection: .offline)
        detail.supportsBrowser = true
        detail.destination = .browser(AgentBrowser.State(agent: Self.zeus, machineName: "dionysus", displayName: "zeus"))
        initial.detail = detail
        let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
            $0.clientTools = Calls().client
        }

        await store.send(.agentBrowserToggled(false)) {
            $0.$isAgentBrowserEnabled.withLock { $0 = false }
            $0.detail?.destination = nil
        }
    }

    // MARK: - The pane

    @Test func handoffDoneAndDeclineSettleTheCall() async {
        let calls = Calls()
        let store = TestStore(initialState: AgentBrowser.State(agent: Self.zeus, machineName: "dionysus", displayName: "zeus")) {
            AgentBrowser()
        } withDependencies: {
            $0.clientTools = calls.client
        }

        await store.send(.handoffDoneTapped(requestID: "ctr_1"))
        await store.send(.handoffDeclineTapped(requestID: "ctr_2"))
        await store.send(.handBackTapped)
        await store.send(.takeControlTapped)
        await store.finish()

        #expect(calls.events.value == [.done(requestID: "ctr_1"), .decline(requestID: "ctr_2"), .giveBack, .pill])
    }

    @Test func doneReachesTheWaitingHandoffThroughTheRuntime() async throws {
        let browser = FakeIOSBrowser()
        let runtime = ClientToolsRuntime(makeBrowser: { _, _ in browser }, makeClient: { _ in FakeProvider() })
        _ = try #require(runtime.openBrowser(for: Self.zeus))
        let handoff = Task { await browser.control.requestHandoff(requestID: "ctr_1", message: "Log in please") }
        await until { browser.control.state.pendingHandoff != nil }

        await ClientToolsClient.live(runtime: runtime).control(Self.zeus, .done(requestID: "ctr_1"))

        #expect(await handoff.value == .done)
        #expect(browser.control.state == .agent)
    }

    // MARK: - The Browser row

    @Test func theBrowserRowShowsOnlyWhenAdvertisedAndEnabled() async {
        var state = AgentDetail.State(daemon: .dionysus, agent: Agent(name: "zeus"), connection: .connected)
        #expect(!state.showsBrowser, "the daemon doesn't advertise client_tools")

        state.supportsBrowser = true
        #expect(state.showsBrowser)

        state.$isBrowserEnabled.withLock { $0 = false }
        #expect(!state.showsBrowser, "the setting is off")
    }

    @Test func theBrowserRowPushesTheAgentsBrowser() async {
        var initial = AgentDetail.State(daemon: .dionysus, agent: Agent(name: "zeus"), connection: .connected)
        initial.supportsBrowser = true
        let store = TestStore(initialState: initial) { AgentDetail() }

        await store.send(.browserButtonTapped) {
            $0.destination = .browser(AgentBrowser.State(agent: Self.zeus, machineName: "dionysus", displayName: "zeus"))
        }
    }

    @Test func theDetailFollowsTheDaemonsClientTools() async {
        var initial = AppFeature.State()
        initial.fleet = Fleet.State(daemons: [.dionysus])
        initial.fleet.sessions[0].agents = [Agent(name: "zeus")]
        initial.detail = AgentDetail.State(daemon: .dionysus, agent: Agent(name: "zeus"), connection: .offline)
        let store = TestStore(initialState: initial) { AppFeature() }
        store.exhaustivity = .off

        await store.send(.fleet(.connected(
            PairedDaemon.dionysus.id, bootID: nil, features: LeoDaemonFeatures(["client_tools"]), LeoObservedState(agents: [.make("zeus")])
        )))

        #expect(store.state.detail?.supportsBrowser == true)
        #expect(store.state.detail?.showsBrowser == true)
    }

    // MARK: - Runtime

    @Test func aDaemonGetsAStreamOnlyWhenItAdvertisesClientTools() async {
        let provider = FakeProvider()
        let runtime = ClientToolsRuntime(makeBrowser: { _, _ in FakeIOSBrowser() }, makeClient: { _ in provider })

        runtime.connected(Self.machine(advertises: false))
        for _ in 0..<50 { await Task.yield() }
        #expect(provider.streams == 0)

        runtime.connected(Self.machine(advertises: true))
        await until { provider.streams == 1 }
    }

    @Test func settingOffStopsStreamsAndClosesBrowsers() async throws {
        let provider = FakeProvider()
        let browser = FakeIOSBrowser()
        let runtime = ClientToolsRuntime(makeBrowser: { _, _ in browser }, makeClient: { _ in provider })
        runtime.connected(Self.machine(advertises: true))
        await until { provider.streams == 1 }
        _ = try #require(runtime.openBrowser(for: Self.zeus))

        runtime.setEnabled(false)

        await until { provider.ended == 1 }
        #expect(browser.isClosed)
        #expect(runtime.openBrowser(for: Self.zeus) == nil, "no browser while the setting is off")
    }

    @Test func suspendClosesStreamsAndResumeReopensThem() async {
        let provider = FakeProvider()
        var foreground: [Bool] = []
        let runtime = ClientToolsRuntime(makeBrowser: { _, _ in FakeIOSBrowser() }, makeClient: { _ in provider })
        runtime.onForegroundChange = { foreground.append($0) }
        runtime.connected(Self.machine(advertises: true))
        await until { provider.streams == 1 }

        await runtime.suspend()
        await until { provider.ended == 1 }
        runtime.connected(Self.machine(advertises: true))
        for _ in 0..<50 { await Task.yield() }
        #expect(provider.streams == 1, "nothing reopens in the background")

        runtime.resume()
        await until { provider.streams == 2 }
        #expect(foreground == [false, true])
    }

    /// Back to the foreground while the first daemon's background answer is
    /// still posting: every daemon ends with a live stream.
    @Test func resumeDuringSuspendLeavesEveryDaemonResumed() async {
        let first = HeldCallProvider(clientID: "ct_1"), second = HeldCallProvider(clientID: "ct_2")
        let runtime = ClientToolsRuntime(
            makeBrowser: { _, _ in BlockingIOSBrowser() },
            makeClient: { $0.daemonID == "d1" ? first : second }
        )
        runtime.connected(Self.machine(advertises: true, daemonID: "d1"))
        runtime.connected(Self.machine(advertises: true, daemonID: "d2"))
        await until { first.claims == 1 && second.claims == 1 }
        first.holdsPosts = true

        let suspending = Task { await runtime.suspend() }
        await until { first.heldPosts == 1 }
        runtime.resume()
        first.releasePosts()
        await suspending.value

        await until { first.openStreams.value == 1 && second.openStreams.value == 1 }
    }

    // MARK: - Helpers

    private static func machine(advertises: Bool, daemonID: String = PairedDaemon.dionysus.id) -> ClientToolsMachine {
        ClientToolsMachine(
            daemonID: daemonID, name: "dionysus",
            endpoint: LeoRemoteEndpoint(baseURL: URL(string: "https://leo.example.com")!, token: "t"), advertisesClientTools: advertises
        )
    }

    private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        await settle { condition() }
    }
}

/// A browser with nothing behind it.
@MainActor final class FakeIOSBrowser: LeoAgentBrowserRunning {
    let control = LeoBrowserControlModel()
    private(set) var isClosed = false

    func execute(_ request: LeoClientToolRequest) async -> LeoClientToolOutcome { .success([.text("ok")]) }
    func openBlankTabIfEmpty() {}
    func close() { isClosed = true }
}

/// A browser whose calls run until cancelled.
@MainActor final class BlockingIOSBrowser: LeoAgentBrowserRunning {
    let control = LeoBrowserControlModel()

    func execute(_ request: LeoClientToolRequest) async -> LeoClientToolOutcome {
        let gate = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in gate.setValue(continuation) }
        } onCancel: {
            gate.withValue { $0?.resume(); $0 = nil }
        }
        return .failure(LeoClientToolError(code: "cancelled", message: ""))
    }

    func openBlankTabIfEmpty() {}
    func close() {}
}

/// A daemon that says hello on every stream and, on the first, hands this
/// client one call it owns; posts can be held to stretch a suspend.
@MainActor final class HeldCallProvider: LeoClientToolsProviding {
    private let clientID: String
    private var streamCount = 0
    let openStreams = LockIsolated(0)
    private(set) var claims = 0
    var holdsPosts = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var heldPosts: Int { held.count }

    init(clientID: String) {
        self.clientID = clientID
    }

    private var request: LeoClientToolRequest {
        LeoClientToolRequest(id: "ctr_\(clientID)", agent: "zeus", group: "browser", tool: "browser_click", args: .object([:]), owner: clientID, timeoutSeconds: 30)
    }

    @MainActor func events() async -> AsyncStream<LeoClientToolsEvent> {
        streamCount += 1
        openStreams.withValue { $0 += 1 }
        let (stream, continuation) = AsyncStream.makeStream(of: LeoClientToolsEvent.self)
        continuation.onTermination = { [openStreams] _ in openStreams.withValue { $0 -= 1 } }
        continuation.yield(.hello(clientID: clientID))
        if streamCount == 1 { continuation.yield(.request(request)) }
        return stream
    }

    @MainActor func register(group: String, tools: [LeoClientToolDefinition]) async throws -> Int { 1 }

    @MainActor func claim(_ requestID: String) async throws -> LeoClientToolRequest {
        claims += 1
        return request
    }

    @MainActor func postResult(_ requestID: String, _ outcome: LeoClientToolOutcome) async throws {
        if holdsPosts { await withCheckedContinuation { held.append($0) } }
    }

    @MainActor func pending() async throws -> [LeoClientToolPending] { [] }

    func releasePosts() {
        holdsPosts = false
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

/// A daemon whose provider streams stay open until the session closes them.
@MainActor final class FakeProvider: LeoClientToolsProviding {
    private(set) var streams = 0
    private(set) var ended = 0

    @MainActor func events() async -> AsyncStream<LeoClientToolsEvent> {
        streams += 1
        let (stream, continuation) = AsyncStream.makeStream(of: LeoClientToolsEvent.self)
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.ended += 1 } }
        return stream
    }

    @MainActor func register(group: String, tools: [LeoClientToolDefinition]) async throws -> Int { 1 }

    @MainActor func claim(_ requestID: String) async throws -> LeoClientToolRequest {
        throw LeoClientToolsError.unknownRequest(message: "unknown")
    }

    @MainActor func postResult(_ requestID: String, _ outcome: LeoClientToolOutcome) async throws {}

    @MainActor func pending() async throws -> [LeoClientToolPending] { [] }
}
