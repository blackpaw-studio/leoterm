import Combine
import Foundation
import Testing

@testable import LeoKit

private let agent = LeoPluginAgentRef(machine: "localhost", name: "alpha")
private let gitSHA = String(repeating: "d", count: 40)

/// `sleep` that the test releases by hand, recording each requested delay.
private final class SleepControl: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var delays: [TimeInterval] = []

    func sleep(_ delay: TimeInterval) async throws {
        lock.withLock { delays.append(delay) }
        await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
    }

    func releaseAll() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting = [] }
            return waiting
        }
        pending.forEach { $0.resume() }
    }
}

private func manifestJSON(
    id: String, network: String = "[]", secrets: Bool = false, agents: String = "[]", contributes: String? = nil,
    apiVersion: Int = 1, credentials: String = "[]"
) -> String {
    let contrib = contributes ?? #"{"views":[{"id":"main","title":"Main","sfSymbol":"star"}],"sidebarSections":[{"id":"issues","title":"Issues"}],"commands":[{"id":"go","title":"Go"}]}"#
    return #"{"id":"\#(id)","name":"\#(id)","version":"1.0.0","apiVersion":\#(apiVersion),"main":"main.js","permissions":{"network":\#(network),"secrets":\#(secrets),"agents":\#(agents),"credentials":\#(credentials)},"contributes":\#(contrib)}"#
}

@MainActor private final class Rig {
    let root: URL
    let bundled: URL
    let store: LeoPluginStore
    let hosts = PluginFakeHostFactory()
    let scheduler = PluginManualScheduler()
    let keychain = PluginFakeKeychain()
    let actions = PluginFakeActions()
    let trash = PluginFakeTrash()
    let sleeper = SleepControl()
    let slots = LeoPluginSlotStore()
    let agentSource = AgentSource()
    var reaperCalls: [Int] = []
    var clockValue: TimeInterval = 0
    /// `leo.credentials` services; nil refuses every credential call.
    var credentials: LeoPluginCredentialServices?
    var manager: LeoPluginManager!

    @MainActor final class AgentSource: LeoPluginAgentSource {
        var agents: [(LeoHostID, LeoAgent)] = []
        func currentAgents() -> [(LeoHostID, LeoAgent)] { agents }
    }

    final class ClockBox: @unchecked Sendable { var value: TimeInterval = 0 }
    let clock = ClockBox()

    init() throws {
        root = try makeTempRoot("leo-manager")
        bundled = root.appendingPathComponent("bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        store = LeoPluginStore(root: root.appendingPathComponent("plugins"))
    }

    func buildManager(withBundled: Bool = true) {
        let factory = hosts
        let clock = clock
        manager = LeoPluginManager(
            LeoPluginManagerDependencies(
                store: store, bundledRoot: withBundled ? bundled : nil, hosts: factory, scheduler: scheduler, keychain: keychain,
                agents: agentSource, actions: actions, trash: trash, slots: slots,
                makeFetcher: { _, _ in PluginFakeFetcher() },
                reapOrphans: { [unowned self] in reaperCalls.append(factory.made.count) },
                clock: { clock.value }, sleep: { [sleeper] in try await sleeper.sleep($0) }, agentsDebounce: 0.5,
                credentials: credentials))
    }

    @discardableResult
    func addBundled(_ id: String, manifest: String? = nil, main: String = "leo.render('x',{})") throws -> URL {
        try addPlugin(in: bundled.appendingPathComponent(id), manifest: manifest ?? manifestJSON(id: id), main: main)
    }

    @discardableResult
    func addPlugin(in dir: URL, manifest: String, main: String = "1") throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("leo-plugin.json"))
        try Data(main.utf8).write(to: dir.appendingPathComponent("main.js"))
        return dir
    }

    func settle() async { for _ in 0..<60 { await Task.yield() } }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func key(_ id: String, _ slot: LeoPluginSlotID) -> LeoPluginSlotKey { LeoPluginSlotKey(pluginID: id, slot: slot) }
    func state(_ id: String) -> LeoPluginRunState? { manager.plugins.first { $0.id == id }?.state }
}

private let demo = "studio.blackpaw.demo"

@MainActor struct LeoPluginManagerTests {
    @Test func aBundledPluginIsRegisteredEnabledAndStartedWithItsBundleAndAnActivate() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo, main: "leo.render('a',{})")
        rig.buildManager()

        rig.manager.reload()

        #expect(rig.store.registry.record(for: demo)?.enabled == true)
        #expect(rig.state(demo) == .running)
        let host = try #require(rig.hosts.last)
        #expect(host.source == "leo.render('a',{})")
        #expect(host.events == [.activate(slot: nil)])
    }

    @Test func everySlotStartsLoadingAndARenderBecomesATree() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let section = LeoPluginSlotID.section(id: "issues")
        #expect(rig.slots.state(rig.key(demo, section)) == .loading)

        let root = try LeoPluginSlotRoot(nodes: [.loading(.init(message: "hi"))])
        rig.hosts.last?.send(.render(slot: section, node: root))

        #expect(rig.slots.state(rig.key(demo, section)) == .tree(root))
    }

    @Test func aRenderForAnUndeclaredContributionIsRefused() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let slot = LeoPluginSlotID.section(id: "not-declared")
        rig.hosts.last?.send(.render(slot: slot, node: try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))])))
        #expect(rig.slots.state(rig.key(demo, slot)) == .loading)
    }

    // MARK: Crashes

    @Test func aCrashShowsTheErrorInEverySlotThenRestartsAfterTheBackoffWithAFreshActivate() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let view = LeoPluginSlotID.view(viewID: "main", agent: agent)
        rig.manager.open(view, plugin: demo)
        let first = try #require(rig.hosts.last)

        first.crash("killed by signal 9")
        await rig.settle()

        for slot in [LeoPluginSlotID.section(id: "issues"), view, .palette(commandID: "go")] {
            guard case .error(let message) = rig.slots.state(rig.key(demo, slot)) else { Issue.record("slot \(slot.key) not in error"); return }
            #expect(message.contains("killed by signal 9"))
        }
        #expect(rig.sleeper.delays == [1])
        #expect(rig.hosts.made.count == 1)   // waiting out the backoff

        rig.sleeper.releaseAll()
        await rig.settle()
        #expect(rig.hosts.made.count == 2)
        #expect(rig.state(demo) == .running)
        // The new host is told to activate, and the open view is asked for again.
        #expect(rig.hosts.last?.events == [.activate(slot: nil), .viewOpened(agent: agent, slot: view)])
        #expect(rig.slots.state(rig.key(demo, view)) == .loading)
    }

    @Test func threeCrashesDisableThePluginAndReenablingRestartsIt() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()

        for round in 1...3 {
            rig.hosts.last?.crash("crash \(round)")
            await rig.settle()
            rig.clock.value += 10
            rig.sleeper.releaseAll()
            await rig.settle()
        }

        guard case .disabled(let reason)? = rig.state(demo) else { Issue.record("not disabled: \(String(describing: rig.state(demo)))"); return }
        #expect(reason.contains("crash 3"))
        #expect(rig.store.registry.record(for: demo)?.disabledReason == reason)
        guard case .disabled = rig.slots.state(rig.key(demo, .section(id: "issues"))) else { Issue.record("slot isn't showing the notice"); return }
        let hostsBefore = rig.hosts.made.count

        try rig.manager.setEnabled(demo, true)

        #expect(rig.state(demo) == .running)
        #expect(rig.hosts.made.count == hostsBefore + 1)
        #expect(rig.store.registry.record(for: demo)?.disabledReason == nil)
    }

    @Test func aHostThatCantStartCountsAsACrash() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.hosts.startError = LeoPluginTestError.boom
        rig.buildManager()
        rig.manager.reload()
        await rig.settle()
        guard case .restarting? = rig.state(demo) else { Issue.record("expected restarting, got \(String(describing: rig.state(demo)))"); return }
    }

    @Test func callbacksFromAReplacedHostAreIgnored() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let old = try #require(rig.hosts.last)
        old.crash()
        await rig.settle()
        rig.sleeper.releaseAll()
        await rig.settle()

        old.send(.render(slot: .section(id: "issues"), node: try LeoPluginSlotRoot(nodes: [.loading(.init(message: "stale"))])))
        old.crash("again")
        await rig.settle()

        #expect(rig.slots.state(rig.key(demo, .section(id: "issues"))) == .loading)
        #expect(rig.state(demo) == .running)
    }

    // MARK: Approval

    @Test func aBundledPluginThatNowAsksForMoreIsNotStartedUntilApproved() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, network: #"["a.example.com"]"#))
        rig.buildManager()
        rig.manager.reload()
        #expect(rig.state(demo) == .running)
        let started = rig.hosts.made.count

        // An app update ships a bigger manifest.
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, network: #"["a.example.com","b.example.com"]"#, secrets: true))
        rig.manager.reload()

        guard case .needsApproval(let diff)? = rig.state(demo) else { Issue.record("expected needsApproval"); return }
        #expect(diff.addedHosts == ["b.example.com"])
        #expect(diff.secretsEnabled)
        #expect(rig.hosts.last?.isStopped == true)
        guard case .disabled = rig.slots.state(rig.key(demo, .section(id: "issues"))) else { Issue.record("slots should show the notice"); return }

        try rig.manager.approveCurrentPermissions(demo)
        #expect(rig.state(demo) == .running)
        #expect(rig.hosts.made.count == started + 1)
    }

    // MARK: Start-up

    @Test func theOrphanReaperRunsOnceBeforeTheFirstSpawn() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        try rig.addBundled("studio.blackpaw.second")
        rig.buildManager()

        rig.manager.reload()
        rig.manager.reload(restarting: [demo])

        #expect(rig.hosts.made.count >= 3)
        #expect(rig.reaperCalls == [0])
    }

    @Test func aPluginWhoseMainEscapesTheFolderIsRefusedAndNeverSpawned() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let dir = try rig.addBundled(demo)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("main.js"))
        let outside = rig.root.appendingPathComponent("outside.js")
        try Data("steal()".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("main.js"), withDestinationURL: outside)
        rig.buildManager()

        rig.manager.reload()

        guard case .refused? = rig.state(demo) else { Issue.record("expected refused, got \(String(describing: rig.state(demo)))"); return }
        #expect(rig.hosts.made.isEmpty)
    }

    // MARK: Enable / disable

    @Test func turningAPluginOffStopsItsHostAndShowsTheNotice() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let host = try #require(rig.hosts.last)

        try rig.manager.setEnabled(demo, false)

        #expect(host.isStopped)
        #expect(rig.state(demo) == .stoppedByUser)
        guard case .disabled = rig.slots.state(rig.key(demo, .section(id: "issues"))) else { Issue.record("expected notice"); return }
        // Stopping isn't a crash: nothing restarts.
        await rig.settle()
        #expect(rig.sleeper.delays.isEmpty)
        #expect(rig.hosts.made.count == 1)
    }

    // MARK: Events

    @Test func openingADeclaredViewSendsViewOpenedAndAnUndeclaredOneIsRefused() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let host = try #require(rig.hosts.last)

        #expect(rig.manager.open(.view(viewID: "main", agent: agent), plugin: demo))
        #expect(!rig.manager.open(.view(viewID: "ghost", agent: agent), plugin: demo))
        #expect(rig.manager.open(.palette(commandID: "go"), plugin: demo))
        #expect(rig.manager.open(.section(id: "issues"), plugin: demo))

        #expect(host.events.dropFirst() == [
            .viewOpened(agent: agent, slot: .view(viewID: "main", agent: agent)),
            .command(id: "go", slot: .palette(commandID: "go")), .activate(slot: .section(id: "issues")),
        ])
    }

    @Test func openingADeclaredPaneSendsViewOpenedAndAnUndeclaredOneIsRefused() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let contributes = #"{"panes":[{"id":"status","title":"Status"}]}"#
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, contributes: contributes))
        rig.buildManager()
        rig.manager.reload()
        let host = try #require(rig.hosts.last)

        let summary = LeoPluginSlotID.pane(id: "status", part: .summary, agent: agent)
        let body = LeoPluginSlotID.pane(id: "status", part: .body, agent: agent)
        #expect(rig.manager.open(summary, plugin: demo))
        #expect(rig.manager.open(body, plugin: demo))
        #expect(!rig.manager.open(.pane(id: "ghost", part: .summary, agent: agent), plugin: demo))

        #expect(host.events.dropFirst() == [.viewOpened(agent: agent, slot: summary), .viewOpened(agent: agent, slot: body)])
        #expect(rig.slots.state(pluginID: demo, slot: summary) == .loading)
    }

    @Test func hidingAPanePublishesItInThePluginInfo() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let contributes = #"{"panes":[{"id":"status","title":"Status"}]}"#
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, contributes: contributes))
        rig.buildManager()
        rig.manager.reload()

        try rig.manager.setPane(demo, pane: "status", hidden: true)
        #expect(rig.manager.plugins.first { $0.id == demo }?.hiddenPanes == ["status"])
        try rig.manager.setPane(demo, pane: "status", hidden: false)
        #expect(rig.manager.plugins.first { $0.id == demo }?.hiddenPanes == [])
    }

    // MARK: usageChanged

    private static let paneContributes = #"{"panes":[{"id":"status","title":"Status"}]}"#
    private let paneSummary = LeoPluginSlotID.pane(id: "status", part: .summary, agent: agent)

    private func paneRig(plugin: String = demo, agents: String = #"["read","usage"]"#) throws -> Rig {
        let rig = try Rig()
        try rig.addBundled(plugin, manifest: manifestJSON(id: plugin, agents: agents, contributes: Self.paneContributes))
        rig.buildManager()
        rig.manager.reload()
        return rig
    }

    private func usageEvents(_ host: PluginFakeHost?) -> [LeoPluginEvent] {
        (host?.events ?? []).filter { if case .usageChanged = $0 { true } else { false } }
    }

    @Test func usageChangedReachesAPluginWithUsageAndAVisiblePaneForThatAgent() async throws {
        let rig = try paneRig()
        defer { rig.cleanup() }
        let host = try #require(rig.hosts.last)
        rig.manager.open(paneSummary, plugin: demo)
        rig.manager.setPaneVisible(plugin: demo, visible: true)

        rig.manager.usageDidChange(agent: agent)
        #expect(usageEvents(host) == [.usageChanged(agent: agent)])
    }

    @Test func nothingIsDeliveredWhileThePaneIsHidden() async throws {
        let rig = try paneRig()
        defer { rig.cleanup() }
        let host = try #require(rig.hosts.last)
        rig.manager.open(paneSummary, plugin: demo)

        rig.manager.usageDidChange(agent: agent)
        #expect(usageEvents(host).isEmpty)

        rig.manager.setPaneVisible(plugin: demo, visible: true)
        rig.manager.setPaneVisible(plugin: demo, visible: false)
        rig.clock.value = 5
        rig.manager.usageDidChange(agent: agent)
        #expect(usageEvents(host).isEmpty)
    }

    @Test func aPluginWithoutUsageNeverGetsTheEvent() async throws {
        let rig = try paneRig(agents: #"["read"]"#)
        defer { rig.cleanup() }
        let host = try #require(rig.hosts.last)
        rig.manager.open(paneSummary, plugin: demo)
        rig.manager.setPaneVisible(plugin: demo, visible: true)

        rig.manager.usageDidChange(agent: agent)
        #expect(usageEvents(host).isEmpty)
    }

    @Test func onlyAgentsThePluginHoldsAPaneSlotForAreDelivered() async throws {
        let rig = try paneRig()
        defer { rig.cleanup() }
        let host = try #require(rig.hosts.last)
        rig.manager.open(paneSummary, plugin: demo)
        rig.manager.setPaneVisible(plugin: demo, visible: true)

        rig.manager.usageDidChange(agent: LeoPluginAgentRef(machine: "localhost", name: "someone-else"))
        #expect(usageEvents(host).isEmpty)
    }

    @Test func aPluginCannotFabricateAPaneSlotToReceiveUsageForAnAgentItWasNeverOpenedFor() async throws {
        let rig = try paneRig()
        defer { rig.cleanup() }
        let host = try #require(rig.hosts.last)
        rig.manager.open(paneSummary, plugin: demo)
        rig.manager.setPaneVisible(plugin: demo, visible: true)

        let victim = LeoPluginAgentRef(machine: "localhost", name: "victim")
        host.send(.render(slot: .pane(id: "status", part: .summary, agent: victim), node: try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))])))
        rig.manager.usageDidChange(agent: victim)
        #expect(usageEvents(host).isEmpty)
    }

    @Test func aBurstIsCoalescedToTheFirstChangePlusOneTrailingEvent() async throws {
        let rig = try paneRig()
        defer { rig.cleanup() }
        let host = try #require(rig.hosts.last)
        rig.manager.open(paneSummary, plugin: demo)
        rig.manager.setPaneVisible(plugin: demo, visible: true)

        for step in 0..<5 {
            rig.clock.value = Double(step) * 0.1
            rig.manager.usageDidChange(agent: agent)
        }
        #expect(usageEvents(host).count == 1)
        rig.clock.value = 1.0
        rig.scheduler.fireAll()
        await rig.settle()
        #expect(usageEvents(host).count == 2)
    }

    @Test func aTrailingEventIsDroppedIfThePaneWentHiddenMeanwhile() async throws {
        let rig = try paneRig()
        defer { rig.cleanup() }
        let host = try #require(rig.hosts.last)
        rig.manager.open(paneSummary, plugin: demo)
        rig.manager.setPaneVisible(plugin: demo, visible: true)

        rig.manager.usageDidChange(agent: agent)
        rig.clock.value = 0.2
        rig.manager.usageDidChange(agent: agent)
        rig.manager.setPaneVisible(plugin: demo, visible: false)
        rig.clock.value = 1.0
        rig.scheduler.fireAll()
        await rig.settle()
        #expect(usageEvents(host).count == 1)
    }

    // MARK: Commands that never render

    @Test func aCommandWhoseHandlerFinishesWithoutRenderingItsSlotIsReported() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let host = try #require(rig.hosts.last)
        var settled: [LeoPluginSlotKey] = []
        let subscription = rig.manager.commandFinishedWithoutRender.sink { settled.append($0) }
        defer { subscription.cancel() }
        let palette = LeoPluginSlotID.palette(commandID: "go")

        #expect(rig.manager.open(palette, plugin: demo))
        host.finishHandler()  // load
        host.finishHandler()  // activate
        #expect(settled.isEmpty)
        host.finishHandler()  // command

        #expect(settled == [rig.key(demo, palette)])
    }

    @Test func aCommandThatRenderedItsSlotIsNotReported() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let host = try #require(rig.hosts.last)
        var settled: [LeoPluginSlotKey] = []
        let subscription = rig.manager.commandFinishedWithoutRender.sink { settled.append($0) }
        defer { subscription.cancel() }
        let palette = LeoPluginSlotID.palette(commandID: "go")

        #expect(rig.manager.open(palette, plugin: demo))
        host.send(.render(slot: palette, node: try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))])))
        for _ in 0..<3 { host.finishHandler() }

        #expect(settled.isEmpty)
    }

    @Test func aCommandStillAwaitingAReplyIsNotReportedUntilTheContinuationFinishes() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let host = try #require(rig.hosts.last)
        var settled: [LeoPluginSlotKey] = []
        let subscription = rig.manager.commandFinishedWithoutRender.sink { settled.append($0) }
        defer { subscription.cancel() }
        let palette = LeoPluginSlotID.palette(commandID: "go")

        #expect(rig.manager.open(palette, plugin: demo))
        host.send(.agentsList(id: "r1"))  // the handler awaits this; the app answers with a reply event
        for _ in 0..<3 { host.finishHandler() }  // load, activate, command
        #expect(settled.isEmpty)
        host.finishHandler()  // the continuation that follows the reply

        #expect(settled == [rig.key(demo, palette)])
    }

    @Test func retryResendsTheEventThatProducedTheErrorSlot() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let view = LeoPluginSlotID.view(viewID: "main", agent: agent)
        rig.manager.open(view, plugin: demo)
        rig.hosts.last?.send(.handlerError(source: "viewOpened", message: "boom"))
        #expect(rig.slots.state(rig.key(demo, view)) == .error("boom"))

        rig.manager.retry(rig.key(demo, view))

        #expect(rig.slots.state(rig.key(demo, view)) == .loading)
        #expect(rig.hosts.last?.events.suffix(2) == [.viewOpened(agent: agent, slot: view), .viewOpened(agent: agent, slot: view)])
    }

    @Test func agentsChangedIsDebouncedAndSentOnlyToPluginsThatCanReadAgents() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, agents: #"["read"]"#))
        try rig.addBundled("studio.blackpaw.blind")
        rig.buildManager()
        rig.manager.reload()

        rig.manager.agentsDidChange()
        rig.manager.agentsDidChange()
        rig.manager.agentsDidChange()
        await rig.settle()
        rig.sleeper.releaseAll()
        await rig.settle()

        let readers = rig.hosts.made.filter { $0.events.contains(.agentsChanged) }
        #expect(readers.count == 1)
        #expect(readers.first?.events.filter { $0 == .agentsChanged }.count == 1)
    }

    @Test func aGesturedClickOnSendToAgentReachesTheConfirmationSheetAndNoGestureDoesNot() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, agents: #"["send"]"#))
        rig.buildManager()
        rig.manager.reload()
        let send = LeoPluginAction.sendToAgent(agent: agent, text: "hello")

        rig.manager.perform(send, plugin: demo, slot: nil, gesture: nil)
        #expect(rig.actions.confirmed.isEmpty)
        rig.manager.perform(send, plugin: demo, slot: nil, gesture: gestureNow())
        #expect(rig.actions.confirmed.count == 1)
        #expect(rig.actions.confirmed.first?.1.name == demo)
    }

    @Test func aCallbackActionIsDeliveredToThePluginWithALiveRef() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, agents: #"["send"]"#))
        rig.buildManager()
        rig.manager.reload()
        let host = try #require(rig.hosts.last)

        rig.manager.perform(.callback(id: "retry", payload: .string("x")), plugin: demo, slot: .section(id: "issues"), gesture: gestureNow())

        guard case .callback(let ref, let id, let payload, let gesture)? = host.events.last else { Issue.record("no callback event"); return }
        #expect(id == "retry")
        #expect(payload == .string("x"))
        #expect(gesture)
        // The plugin quotes the ref to resolve one follow-up.
        host.send(.callbackResult(ref: ref, action: .sendToAgent(agent: agent, text: "hi")))
        #expect(rig.actions.confirmed.count == 1)
    }

    @Test func aTimerFireReachesThePlugin() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let host = try #require(rig.hosts.last)

        host.send(.timerStart(id: "t1", seconds: 60))
        rig.scheduler.fireAll()
        await rig.settle()

        #expect(host.events.contains(.timerFired(id: "t1")))
    }

    @Test func aRestartDoesNotReplayThePaletteCommand() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let palette = LeoPluginSlotID.palette(commandID: "go")
        rig.manager.open(palette, plugin: demo)

        try #require(rig.hosts.last).crash("boom")
        await rig.settle()
        rig.sleeper.releaseAll()
        await rig.settle()

        #expect(rig.hosts.last?.events == [.activate(slot: nil)])
    }

    @Test func retryOnAPaletteSlotResendsTheCommandNotAnActivate() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        let palette = LeoPluginSlotID.palette(commandID: "go")
        let host = try #require(rig.hosts.last)

        rig.manager.retry(rig.key(demo, palette))

        #expect(host.events.last == .command(id: "go", slot: palette))
    }

    // MARK: Slot visibility survives a new session

    @Test func aVisibleSlotStaysVisibleAfterACrashRestartSoAfterStillFires() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        rig.manager.setSlotVisible(plugin: demo, visible: true)

        try #require(rig.hosts.last).crash("boom")
        await rig.settle()
        rig.sleeper.releaseAll()
        await rig.settle()
        let second = try #require(rig.hosts.last)
        second.send(.afterStart(id: "a1", seconds: 5))
        rig.scheduler.fireAll()
        await rig.settle()

        #expect(second.events.contains(.timerFired(id: "a1")))
    }

    @Test func aVisibleSlotStaysVisibleAfterDisableThenEnable() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        rig.manager.setSlotVisible(plugin: demo, visible: true)

        try rig.manager.setEnabled(demo, false)
        try rig.manager.setEnabled(demo, true)
        let host = try #require(rig.hosts.last)
        host.send(.afterStart(id: "a1", seconds: 5))
        rig.scheduler.fireAll()
        await rig.settle()

        #expect(host.events.contains(.timerFired(id: "a1")))
    }

    @Test func aSlotThatWentHiddenBeforeTheRestartStaysHidden() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        rig.manager.setSlotVisible(plugin: demo, visible: true)
        rig.manager.setSlotVisible(plugin: demo, visible: false)

        try #require(rig.hosts.last).crash("boom")
        await rig.settle()
        rig.sleeper.releaseAll()
        await rig.settle()
        let second = try #require(rig.hosts.last)
        second.send(.afterStart(id: "a1", seconds: 5))
        rig.scheduler.fireAll()
        await rig.settle()

        #expect(!second.events.contains(.timerFired(id: "a1")))
    }

    // MARK: Uninstall

    @Test func uninstallStopsTrashesDeletesOnlyItsOwnSecretsAndForgetsThePlugin() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let folder = rig.store.root.appendingPathComponent("\(demo)/\(gitSHA)")
        try rig.addPlugin(in: folder, manifest: manifestJSON(id: demo, secrets: true))
        try rig.store.update {
            $0.registerInstalled(
                LeoPluginManifest(id: demo, name: "Demo", version: "1.0.0", apiVersion: 1, main: "main.js", permissions: LeoPluginPermissions(secrets: true)),
                url: "https://github.com/x/demo", ref: "main", sha: gitSHA)
        }
        try rig.keychain.set(service: "leo.plugin.\(demo)", account: "token", value: "mine")
        try rig.keychain.set(service: "leo.plugin.\(demo).other", account: "token", value: "someone else's")
        rig.buildManager(withBundled: false)
        rig.manager.reload()
        let host = try #require(rig.hosts.last)

        try rig.manager.uninstall(demo)

        #expect(host.isStopped)
        #expect(rig.trash.trashed.map(\.lastPathComponent) == [demo])
        #expect(try rig.keychain.get(service: "leo.plugin.\(demo)", account: "token") == nil)
        #expect(try rig.keychain.get(service: "leo.plugin.\(demo).other", account: "token") == "someone else's")
        #expect(rig.store.registry.record(for: demo) == nil)
        #expect(rig.manager.plugins.isEmpty)
        #expect(rig.slots.state(rig.key(demo, .section(id: "issues"))) == .loading)
    }

    @Test func aBundledPluginCantBeUninstalledAndADevFolderIsLeftInPlace() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        let devDir = try rig.addPlugin(in: rig.root.appendingPathComponent("dev"), manifest: manifestJSON(id: "studio.blackpaw.dev"))
        try rig.store.update { $0.registerDev(LeoPluginManifest(id: "studio.blackpaw.dev", name: "Dev", version: "1.0.0", apiVersion: 1, main: "main.js"), path: devDir.path) }
        rig.buildManager()
        rig.manager.reload()

        #expect(throws: LeoPluginManagerError.cannotUninstallBundled(demo)) { try rig.manager.uninstall(demo) }
        try rig.manager.uninstall("studio.blackpaw.dev")
        #expect(FileManager.default.fileExists(atPath: devDir.appendingPathComponent("main.js").path))
        #expect(rig.trash.trashed.isEmpty)
        #expect(rig.store.registry.record(for: "studio.blackpaw.dev") == nil)
    }

    // MARK: Dev

    @Test func aDevChangeRestartsThePluginWithTheNewBundle() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let devDir = try rig.addPlugin(in: rig.root.appendingPathComponent("dev"), manifest: manifestJSON(id: "studio.blackpaw.dev"), main: "v1")
        try rig.store.update { $0.registerDev(LeoPluginManifest(id: "studio.blackpaw.dev", name: "Dev", version: "1.0.0", apiVersion: 1, main: "main.js"), path: devDir.path) }
        rig.buildManager(withBundled: false)
        rig.manager.reload()
        #expect(rig.hosts.last?.source == "v1")

        try Data("v2".utf8).write(to: devDir.appendingPathComponent("main.js"))
        rig.manager.devPluginChanged("studio.blackpaw.dev")

        #expect(rig.hosts.made.count == 2)
        #expect(rig.hosts.made.first?.isStopped == true)
        #expect(rig.hosts.last?.source == "v2")
    }

    @Test func aDevFolderThatClaimsABundledIdDoesNotKnockTheBundledPluginOffline() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo, main: "bundled")
        let devDir = try rig.addPlugin(in: rig.root.appendingPathComponent("dev"), manifest: manifestJSON(id: "studio.blackpaw.dev"), main: "dev")
        try rig.store.update { $0.registerDev(LeoPluginManifest(id: "studio.blackpaw.dev", name: "Dev", version: "1.0.0", apiVersion: 1, main: "main.js"), path: devDir.path) }
        rig.buildManager()
        rig.manager.reload()
        #expect(rig.state(demo) == .running)

        // The author edits the dev manifest to claim the bundled plugin's id.
        try Data(manifestJSON(id: demo).utf8).write(to: devDir.appendingPathComponent("leo-plugin.json"))
        rig.manager.devPluginChanged("studio.blackpaw.dev")

        #expect(rig.state(demo) == .running)
        #expect(rig.hosts.made.filter { $0.source == "bundled" }.count == 1)   // never restarted or replaced
        #expect(rig.hosts.made.first { $0.source == "bundled" }?.isStopped == false)
        guard case .refused = rig.state("studio.blackpaw.dev") else {
            Issue.record("dev plugin should be refused, was \(String(describing: rig.state("studio.blackpaw.dev")))")
            return
        }
    }

    @Test func stoppingOrRemovingAPluginCancelsItsOpenConfirmations() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        let other = "studio.blackpaw.other"
        let devDir = try rig.addPlugin(in: rig.root.appendingPathComponent("dev"), manifest: manifestJSON(id: other))
        try rig.store.update { $0.registerDev(LeoPluginManifest(id: other, name: "Other", version: "1.0.0", apiVersion: 1, main: "main.js"), path: devDir.path) }
        rig.buildManager()
        rig.manager.reload()
        #expect(rig.actions.cancelled.isEmpty)

        try rig.manager.setEnabled(demo, false)
        #expect(rig.actions.cancelled.contains(demo))
        #expect(!rig.actions.cancelled.contains(other))

        try rig.manager.uninstall(other)
        #expect(rig.actions.cancelled.contains(other))
    }

    @Test func aReloadWithNothingChangedLeavesTheHostAlone() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        rig.manager.reload()
        #expect(rig.hosts.made.count == 1)
    }
}

private enum LeoPluginTestError: Error { case boom }

// MARK: - apiVersion 2

extension LeoPluginManagerTests {
    @Test func eachHostIsMadeAtItsPluginsManifestAPIVersion() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        try rig.addBundled("studio.blackpaw.usage", manifest: manifestJSON(id: "studio.blackpaw.usage", apiVersion: 2))
        rig.buildManager()
        rig.manager.reload()
        #expect(rig.hosts.made.map(\.apiVersion).sorted() == [1, 2])
    }

    @Test func uninstallingAPluginLeavesNoCredentialGrants() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let id = "studio.blackpaw.usage"
        let permissions = LeoPluginPermissions(network: ["chatgpt.com"], credentials: [.codex])
        let manifest = LeoPluginManifest(id: id, name: "Usage", version: "1.0.0", apiVersion: 2, main: "main.js", permissions: permissions)
        let devDir = try rig.addPlugin(
            in: rig.root.appendingPathComponent("usage"),
            manifest: manifestJSON(id: id, network: #"["chatgpt.com"]"#, apiVersion: 2, credentials: #"["codex"]"#))
        try rig.store.update {
            $0.registerDev(manifest, path: devDir.path)
            _ = $0.addGrant(pluginID: id, kind: .codex, path: "/Users/a/.codex", id: "g1")
        }
        rig.buildManager()
        rig.manager.reload()

        try rig.manager.uninstall(id)
        try rig.store.update { $0.registerDev(manifest, path: devDir.path) }
        #expect(rig.store.registry.grants(for: id).isEmpty)
    }

    @Test func grantedAccountsShowOnThePluginAndCanBeRemoved() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let id = "studio.blackpaw.usage"
        let permissions = LeoPluginPermissions(network: ["chatgpt.com"], credentials: [.codex])
        let manifest = LeoPluginManifest(id: id, name: "Usage", version: "1.0.0", apiVersion: 2, main: "main.js", permissions: permissions)
        let devDir = try rig.addPlugin(
            in: rig.root.appendingPathComponent("usage"),
            manifest: manifestJSON(id: id, network: #"["chatgpt.com"]"#, apiVersion: 2, credentials: #"["codex"]"#))
        try rig.store.update {
            $0.registerDev(manifest, path: devDir.path)
            _ = $0.addGrant(pluginID: id, kind: .codex, path: "/Users/a/.codex", id: "g1")
        }
        rig.buildManager()
        rig.manager.reload()
        #expect(rig.manager.plugins.first { $0.id == id }?.credentialGrants.map(\.id) == ["g1"])

        try rig.manager.removeCredentialGrant(id, grantID: "g1")
        #expect(rig.manager.plugins.first { $0.id == id }?.credentialGrants.isEmpty == true)
        #expect(rig.store.registry.grants(for: id).isEmpty)
    }

    /// Registers the bundled plugin's record first, so the hide sticks before its first start.
    private func hideSection(_ section: String, contributes: String, in rig: Rig) throws {
        let manifest = try JSONDecoder().decode(LeoPluginManifest.self, from: Data(manifestJSON(id: demo, contributes: contributes, apiVersion: 2).utf8))
        try rig.store.update {
            $0.registerBundled(manifest)
            $0.setSection(demo, section: section, hidden: true)
        }
    }

    /// The section header's accessory must show while the section is collapsed,
    /// so a v2 plugin hears about its sections at start, opened or not.
    @Test func aV2PluginsSidebarSectionsAreActivatedAtStartEvenWhenNeverOpened() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let contributes = #"{"sidebarSections":[{"id":"usage","title":"Usage"},{"id":"spare","title":"Spare"}]}"#
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, contributes: contributes, apiVersion: 2))
        rig.buildManager()
        try hideSection("spare", contributes: contributes, in: rig)

        rig.manager.reload()

        let section = LeoPluginSlotID.section(id: "usage")
        #expect(rig.hosts.last?.events == [.activate(slot: nil), .activate(slot: section)])
        #expect(rig.manager.slots.isHostOpened(pluginID: demo, slot: section))
    }

    @Test func aV1PluginsSectionsStillWaitUntilOpened() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        #expect(rig.hosts.last?.events == [.activate(slot: nil)])
    }

    @Test func showingAHiddenV2SectionActivatesIt() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let contributes = #"{"sidebarSections":[{"id":"usage","title":"Usage"}]}"#
        try rig.addBundled(demo, manifest: manifestJSON(id: demo, contributes: contributes, apiVersion: 2))
        rig.buildManager()
        try hideSection("usage", contributes: contributes, in: rig)
        rig.manager.reload()

        try rig.manager.setSection(demo, section: "usage", hidden: false)

        #expect(rig.hosts.last?.events == [.activate(slot: nil), .activate(slot: .section(id: "usage"))])
    }
}

// MARK: - credentialsChanged

/// `leo.credentials` with no picker answer and no readable sign-in: enough
/// for the list and remove calls, which never read a token.
private struct NoPicker: LeoPluginCredentialPicking {
    func pickFolder(for kind: LeoPluginCredentialKind) async -> String? { nil }
}

private struct NoResolver: LeoPluginCredentialResolving {
    func resolve(_ grant: LeoPluginCredentialGrant, allowUI: Bool) throws(LeoPluginCredentialError) -> LeoPluginFetchCredential {
        throw .invalid
    }
}

private let usage = "studio.blackpaw.usage"
private let other = "studio.blackpaw.other"

extension LeoPluginManagerTests {
    /// A dev apiVersion 2 plugin approved for Codex accounts, holding one.
    private func addAccountsPlugin(_ id: String, grantID: String, in rig: Rig) throws {
        let permissions = LeoPluginPermissions(network: ["chatgpt.com"], credentials: [.codex])
        let manifest = LeoPluginManifest(id: id, name: id, version: "1.0.0", apiVersion: 2, main: "main.js", permissions: permissions)
        let dir = try rig.addPlugin(
            in: rig.root.appendingPathComponent(id),
            manifest: manifestJSON(id: id, network: #"["chatgpt.com"]"#, apiVersion: 2, credentials: #"["codex"]"#),
            main: "leo.log('info', 'plugin \(id)')")
        try rig.store.update {
            $0.registerDev(manifest, path: dir.path)
            _ = $0.addGrant(pluginID: id, kind: .codex, path: "/Users/a/.codex-\(grantID)", id: grantID)
        }
    }

    private func host(_ id: String, in rig: Rig) -> PluginFakeHost? {
        rig.hosts.made.last { $0.source?.contains("plugin \(id)'") == true }
    }

    private func accountChanges(_ host: PluginFakeHost?) -> Int {
        (host?.events ?? []).filter { $0 == .credentialsChanged }.count
    }

    @Test func aSettingsRemovalTellsOnlyThatPluginItsAccountsChanged() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try addAccountsPlugin(usage, grantID: "g1", in: rig)
        try addAccountsPlugin(other, grantID: "g2", in: rig)
        rig.buildManager()
        rig.manager.reload()

        try rig.manager.removeCredentialGrant(usage, grantID: "g1")

        #expect(accountChanges(host(usage, in: rig)) == 1)
        #expect(accountChanges(host(other, in: rig)) == 0)
    }

    /// `leo.credentials.remove` takes the same path as Settings' Remove:
    /// Settings shows the account gone and the plugin hears about it.
    @Test func aPluginsOwnRemoveRefreshesSettingsAndTellsThePlugin() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try addAccountsPlugin(usage, grantID: "g1", in: rig)
        rig.credentials = LeoPluginCredentialServices(picker: NoPicker(), resolver: NoResolver(), grants: rig.store, home: "/Users/a")
        rig.buildManager()
        rig.manager.reload()
        let plugin = try #require(host(usage, in: rig))

        plugin.send(.credentialsRemove(id: "r1", credential: "g1"))
        await rig.settle()

        #expect(plugin.events.contains(.reply(id: "r1", outcome: .value(.null))))
        #expect(rig.manager.plugins.first { $0.id == usage }?.credentialGrants.isEmpty == true)
        #expect(accountChanges(plugin) == 1)
    }

    /// The manifest stops asking for Codex accounts; approving that narrows
    /// the permissions, which drops the account.
    @Test func narrowedPermissionsThatDropAnAccountTellThePlugin() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try addAccountsPlugin(usage, grantID: "g1", in: rig)
        rig.buildManager()
        rig.manager.reload()
        try rig.addPlugin(
            in: rig.root.appendingPathComponent(usage), manifest: manifestJSON(id: usage, apiVersion: 2), main: "leo.log('info', 'plugin \(usage)')")
        rig.manager.reload(restarting: [usage])

        try rig.manager.approveCurrentPermissions(usage)

        #expect(rig.store.registry.grants(for: usage).isEmpty)
        #expect(accountChanges(host(usage, in: rig)) == 1)
    }

    @Test func aV1PluginNeverHearsCredentialsChanged() async throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try rig.addBundled(demo)
        rig.buildManager()
        rig.manager.reload()
        // A v1 manifest can't ask for credentials, so put an account on its record directly to reach the version check.
        try rig.store.update {
            $0.approve(demo, permissions: LeoPluginPermissions(credentials: [.codex]))
            _ = $0.addGrant(pluginID: demo, kind: .codex, path: "/Users/a/.codex", id: "g1")
        }

        try rig.manager.removeCredentialGrant(demo, grantID: "not-there")  // publishes the change

        #expect(rig.manager.plugins.first { $0.id == demo }?.credentialGrants.map(\.id) == ["g1"])
        #expect(accountChanges(rig.hosts.last) == 0)
    }
}
