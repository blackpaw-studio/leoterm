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
    id: String, network: String = "[]", secrets: Bool = false, agents: String = "[]", contributes: String? = nil
) -> String {
    let contrib = contributes ?? #"{"views":[{"id":"main","title":"Main","sfSymbol":"star"}],"sidebarSections":[{"id":"issues","title":"Issues"}],"commands":[{"id":"go","title":"Go"}]}"#
    return #"{"id":"\#(id)","name":"\#(id)","version":"1.0.0","apiVersion":1,"main":"main.js","permissions":{"network":\#(network),"secrets":\#(secrets),"agents":\#(agents)},"contributes":\#(contrib)}"#
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
                clock: { clock.value }, sleep: { [sleeper] in try await sleeper.sleep($0) }, agentsDebounce: 0.5))
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
