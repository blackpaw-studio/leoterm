import Foundation
import Testing

@testable import LeoKit

private let identity = LeoPluginIdentity(id: "studio.blackpaw.demo", name: "Demo")
private let target = LeoPluginAgentRef(machine: "studio-mac", name: "alpha")

@MainActor private final class FakeCommands: LeoPluginAgentCommands, @unchecked Sendable {
    nonisolated(unsafe) var messages: [(String, String)] = []
    nonisolated(unsafe) var spawns: [LeoSpawnRequest] = []
    nonisolated(unsafe) var failure: Error?
    nonisolated func message(_ name: String, text: String) async throws {
        if let failure { throw failure }
        messages.append((name, text))
    }
    nonisolated func spawn(_ request: LeoSpawnRequest) async throws {
        if let failure { throw failure }
        spawns.append(request)
    }
}

@MainActor private final class FakeAccess: LeoPluginDaemonAccess {
    var machines = ["localhost", "studio-mac"]
    var defaultMachine = "localhost"
    var connected: [String: FakeCommands] = [:]
    private(set) var resolved: [String] = []
    func commands(forMachine name: String) -> (any LeoPluginAgentCommands)? {
        resolved.append(name)
        return connected[name]
    }
}

@MainActor private final class FakeConfirmer: LeoPluginConfirming {
    var sendReply: String?
    var spawnReply: LeoPluginSpawnSpec?
    private(set) var sendDrafts: [LeoPluginSendDraft] = []
    private(set) var spawnDrafts: [LeoPluginSpawnDraft] = []
    /// What the daemon had received when the sheet was on screen.
    var onShow: () -> Void = {}
    func confirmSend(_ draft: LeoPluginSendDraft) async -> String? {
        sendDrafts.append(draft)
        onShow()
        return sendReply
    }
    func confirmSpawn(_ draft: LeoPluginSpawnDraft) async -> LeoPluginSpawnSpec? {
        spawnDrafts.append(draft)
        onShow()
        return spawnReply
    }
}

@MainActor private final class FakeEffects: LeoPluginActionEffects {
    private(set) var opened: [URL] = []
    private(set) var copied: [String] = []
    private(set) var reports: [String] = []
    func open(_ url: URL) { opened.append(url) }
    func copy(_ text: String) { copied.append(text) }
    func report(plugin: LeoPluginIdentity, message: String) { reports.append(message) }
}

@MainActor private struct Rig {
    let access = FakeAccess()
    let confirmer = FakeConfirmer()
    let effects = FakeEffects()
    let slots = LeoPluginSlotStore()
    let studio = FakeCommands()
    let local = FakeCommands()
    let executor: LeoPluginActionExecutor

    init() {
        access.connected = ["studio-mac": studio, "localhost": local]
        executor = LeoPluginActionExecutor(daemons: access, confirmer: confirmer, effects: effects, slots: slots)
    }
}

@MainActor struct LeoPluginActionExecutorTests {
    @Test func noDaemonCallHappensBeforeTheUserConfirmsAndTheEditedTextIsWhatIsSent() async {
        let rig = Rig()
        rig.confirmer.sendReply = "edited text"
        // While the sheet is open nothing may have reached any daemon.
        rig.confirmer.onShow = { #expect(rig.studio.messages.isEmpty && rig.local.messages.isEmpty) }

        await rig.executor.run(.confirm(.sendToAgent(agent: target, text: "original")), plugin: identity)

        #expect(rig.confirmer.sendDrafts == [LeoPluginSendDraft(pluginName: "Demo", agent: target, text: "original")])
        #expect(rig.studio.messages.map(\.1) == ["edited text"])
        #expect(rig.studio.messages.first?.0 == "alpha")
        #expect(rig.local.messages.isEmpty)
    }

    @Test func cancellingSendsNothingAndResolvesNoDaemon() async {
        let rig = Rig()
        rig.confirmer.sendReply = nil
        rig.confirmer.spawnReply = nil

        await rig.executor.run(.confirm(.sendToAgent(agent: target, text: "x")), plugin: identity)
        await rig.executor.run(.confirm(.spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "p", machine: nil))), plugin: identity)

        #expect(rig.studio.messages.isEmpty && rig.studio.spawns.isEmpty && rig.local.spawns.isEmpty)
        #expect(rig.access.resolved.isEmpty)
        #expect(rig.effects.reports.isEmpty)
    }

    @Test func spawnOpensTheSheetOnLeosDefaultMachineAndSendsTheEditedFields() async {
        let rig = Rig()
        rig.confirmer.spawnReply = LeoPluginSpawnSpec(repo: "acme/edited", branch: "fix/it", base: "develop", prompt: "edited prompt", machine: "studio-mac", template: "implementer")

        await rig.executor.run(
            .confirm(.spawnAgent(LeoPluginSpawnSpec(repo: "acme/orig", branch: "orig", base: nil, prompt: "orig prompt", machine: nil))), plugin: identity)

        let draft = rig.confirmer.spawnDrafts.first
        #expect(draft?.spec.machine == "localhost")          // defaulted before the sheet shows
        #expect(draft?.machines == ["localhost", "studio-mac"])
        #expect(draft?.pluginName == "Demo")
        #expect(rig.studio.spawns.count == 1)
        let request = rig.studio.spawns.first
        #expect(request?.repo == "acme/edited")
        #expect(request?.branch == "fix/it")
        #expect(request?.base == "develop")
        #expect(request?.prompt == "edited prompt")
        #expect(rig.local.spawns.isEmpty)
    }

    @Test func spawnSendsTheTemplateTheUserSelectedNotTheOneThePluginProposed() async {
        let rig = Rig()
        rig.confirmer.spawnReply = LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "p", machine: "localhost", template: "implementer")
        await rig.executor.run(
            .confirm(.spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "p", machine: nil, template: "reviewer"))), plugin: identity)
        #expect(rig.confirmer.spawnDrafts.first?.spec.template == "reviewer")   // preselection only
        #expect(rig.local.spawns.map(\.template) == ["implementer"])
    }

    @Test func aSpawnWithNoTemplateSelectedIsRefusedAndReported() async {
        let rig = Rig()
        for blank in [nil, "", "  "] as [String?] {
            rig.confirmer.spawnReply = LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "p", machine: "localhost", template: blank)
            await rig.executor.run(
                .confirm(.spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "p", machine: nil, template: "reviewer"))), plugin: identity)
        }
        #expect(rig.local.spawns.isEmpty)
        #expect(rig.effects.reports.count == 3)
    }

    @Test func theSpawnTemplateRoundTripsOnTheWire() throws {
        let json = Data(#"{"type":"spawnAgent","repo":"a/b","branch":"x","prompt":"p","template":"t"}"#.utf8)
        let action = try JSONDecoder().decode(LeoPluginAction.self, from: json)
        #expect(action == .spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "p", machine: nil, template: "t")))
        let again = try JSONDecoder().decode(LeoPluginAction.self, from: JSONEncoder().encode(action))
        #expect(again == action)
    }

    @Test func aPluginChosenMachineIsKeptWhenItIsConnected() async {
        let rig = Rig()
        rig.confirmer.spawnReply = LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "", machine: "studio-mac")
        await rig.executor.run(.confirm(.spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "", machine: "studio-mac"))), plugin: identity)
        #expect(rig.confirmer.spawnDrafts.first?.spec.machine == "studio-mac")
    }

    @Test func aSpawnWithABlankRepoOrBranchAfterEditingIsRefused() async {
        let rig = Rig()
        rig.confirmer.spawnReply = LeoPluginSpawnSpec(repo: "  ", branch: "x", base: nil, prompt: "p", machine: "localhost")
        await rig.executor.run(.confirm(.spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "p", machine: nil))), plugin: identity)
        #expect(rig.local.spawns.isEmpty)
        #expect(rig.effects.reports.count == 1)
    }

    @Test func aMachineWithNoConnectionIsReportedNotSilentlyDropped() async {
        let rig = Rig()
        rig.access.connected["studio-mac"] = nil
        rig.confirmer.sendReply = "hi"
        await rig.executor.run(.confirm(.sendToAgent(agent: target, text: "hi")), plugin: identity)
        #expect(rig.effects.reports.count == 1)
        #expect(rig.effects.reports.first?.contains("studio-mac") == true)
    }

    @Test func aDaemonFailureIsReported() async {
        let rig = Rig()
        rig.studio.failure = LeoDaemonError.timeout
        rig.confirmer.sendReply = "hi"
        await rig.executor.run(.confirm(.sendToAgent(agent: target, text: "hi")), plugin: identity)
        #expect(rig.effects.reports.count == 1)
    }

    @Test func anOversizedMessageIsRefusedBeforeTheSheetOpens() async {
        let rig = Rig()
        rig.confirmer.sendReply = "x"
        await rig.executor.run(.confirm(.sendToAgent(agent: target, text: String(repeating: "a", count: LeoPluginActionExecutor.maxTextBytes + 1))), plugin: identity)
        #expect(rig.confirmer.sendDrafts.isEmpty)
        #expect(rig.effects.reports.count == 1)
    }

    @Test func sendAndSpawnNeverRunAsPerformedActions() async {
        let rig = Rig()
        rig.executor.perform(.sendToAgent(agent: target, text: "x"), plugin: identity, slot: nil)
        rig.executor.perform(.spawnAgent(LeoPluginSpawnSpec(repo: "a/b", branch: "x", base: nil, prompt: "", machine: nil)), plugin: identity, slot: nil)
        await Task.yield()
        #expect(rig.studio.messages.isEmpty && rig.local.spawns.isEmpty && rig.access.resolved.isEmpty)
        #expect(rig.confirmer.sendDrafts.isEmpty && rig.confirmer.spawnDrafts.isEmpty)
    }

    @Test func confirmingNonAgentActionsIsIgnored() async {
        let rig = Rig()
        await rig.executor.run(.confirm(.copy("x")), plugin: identity)
        #expect(rig.effects.copied.isEmpty)
    }

    @Test func copyAndHttpsOpenURLRunDirectlyAndHttpIsRefused() {
        let rig = Rig()
        rig.executor.perform(.copy("hello"), plugin: identity, slot: nil)
        rig.executor.perform(.openURL("https://example.com/x"), plugin: identity, slot: nil)
        rig.executor.perform(.openURL("http://example.com/x"), plugin: identity, slot: nil)
        rig.executor.perform(.openURL("https://user:pw@example.com/"), plugin: identity, slot: nil)
        rig.executor.perform(.openURL("file:///etc/passwd"), plugin: identity, slot: nil)
        #expect(rig.effects.copied == ["hello"])
        #expect(rig.effects.opened.map(\.absoluteString) == ["https://example.com/x"])
    }

    @Test func pushViewGoesOntoTheSlotsStackAndNeedsASlot() {
        let rig = Rig()
        let slot = LeoPluginSlotID.palette(commandID: "go")
        rig.executor.perform(.pushView(node: .loading(.init(message: "x"))), plugin: identity, slot: slot)
        rig.executor.perform(.pushView(node: .loading(.init(message: "y"))), plugin: identity, slot: nil)
        #expect(rig.slots.pushed[LeoPluginSlotKey(pluginID: identity.id, slot: slot)]?.count == 1)
    }

    @Test func confirmationsAreCappedSoASheetFloodIsDropped() async {
        let rig = Rig()
        for _ in 0..<(LeoPluginActionExecutor.maxPendingConfirmations + 3) {
            rig.executor.confirm(.sendToAgent(agent: target, text: "x"), plugin: identity)
        }
        #expect(rig.effects.reports.count == 3)
    }
}
