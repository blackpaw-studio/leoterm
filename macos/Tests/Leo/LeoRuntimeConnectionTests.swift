import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Per-connection wiring: `LeoRuntime` binds each machine's feed and agent
/// actions to the daemon that machine's connection resolves to.
@MainActor struct LeoRuntimeConnectionTests {
    @Test func startupRoutesListAndActionRequestsToTheSelectedConnectionsDaemon() async throws {
        let daemon = RuntimeTestDaemon()
        let defaults = LeoInMemoryDefaults()
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: daemon, cli: .recordingForTests(), activitySource: activitySource, defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner(), machineRunner: LeoRecordingTemplateRunner(), chatClient: FakeChatClient())
        _ = runtime.makeWindowSession()

        runtime.start()

        await awaitCondition(message: "This Mac's feed never listed against its daemon") {
            await daemon.listCallCount >= 1
        }

        runtime.actions.start(.init(host: .local, name: "alpha", template: nil, status: .running, activity: .unknown, actionDetail: nil))
        await awaitCondition(message: "the action never reached This Mac's daemon") {
            await daemon.startCalls == ["alpha"]
        }

        runtime.shutdown()
    }

    /// `LeoRuntime.shutdown()` is the AppDelegate quit hook's entry point --
    /// it must synchronously engage `LeoMachineRegistry.shutdown()` (which
    /// tears every tunnel down under one bound, see
    /// `LeoMachineRegistryTests`). Verified here via its observable effect:
    /// nothing connects after `shutdown()`.
    @Test func shutdownSynchronouslyEngagesTheRegistrysShutdown() throws {
        let daemon = RuntimeTestDaemon()
        let defaults = LeoInMemoryDefaults()
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(daemon: daemon, cli: .recordingForTests(), activitySource: activitySource, defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner(), machineRunner: LeoRecordingTemplateRunner(), chatClient: FakeChatClient())

        runtime.shutdown()

        runtime.machines.start(flavor: .socketEvents)
        runtime.machines.reconnect(.local)

        #expect(runtime.machines.connectionState(for: .local) == nil, "nothing may connect after shutdown()")
    }

    /// B-061: a remote machine connecting loads its templates through the
    /// runner `LeoRuntime` was given -- the same ssh exec production runs,
    /// but no real `ssh` process is launched against the machine.
    @Test func aRemoteMachineConnectingFetchesItsTemplatesThroughTheInjectedRunner() async throws {
        let configuration = LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        let defaults = LeoInMemoryDefaults()
        defaults.set(try JSONEncoder().encode([configuration]), forKey: LeoHostStore.key)
        let templateRunner = LeoRecordingTemplateRunner()
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(
            daemon: RuntimeTestDaemon(), cli: .recordingForTests(), activitySource: activitySource, defaults: defaults,
            templateFetchRunner: templateRunner, machineRunner: templateRunner,
            machineLegacySocketDirectory: LeoMachineTunnelTestSupport.localSocketDirectory,
            machineControlSocketDirectory: LeoMachineTunnelTestSupport.localSocketDirectory,
            makeTunnel: LeoFakeTunnels().factory,
            remoteDaemon: { _, _ in LeoMachineDaemon(daemon: RuntimeTestDaemon(), activitySource: activitySource, chat: FakeChatClient()) },
            feedsRemoteMachines: true,
            chatClient: FakeChatClient()
        )
        defer { runtime.shutdown() }

        runtime.machines.start(flavor: .socketEvents)

        await awaitCondition(timeout: 5, message: "the remote host's templates never loaded") {
            await runtime.actions.templateList(for: .remote("work")) == .loaded([])
        }
        let calls = await templateRunner.calls
        #expect(calls.count == 1, "one template fetch per host connection, got \(calls)")
        let call = try #require(calls.first)
        #expect(call.executable == "/usr/bin/ssh", "production's ssh exec, handed to the injected runner")
        #expect(call.arguments == ["-o", "BatchMode=yes", "evan@work", "~/'.local/bin/leo' 'template' 'list' '--json'"])
    }

    /// B-112: connecting This Mac loads its templates through the `LeoCLI`
    /// `LeoRuntime` was given -- the same `leo template list --json`
    /// production runs, but no real local `leo` process is launched.
    @Test func thisMacConnectingFetchesTemplatesThroughTheInjectedCLIRunner() async throws {
        let recorder = LeoRecordingTemplateRunner(templates: ["local-template"])
        let activitySource = LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] })
        let runtime = LeoRuntime(
            daemon: RuntimeTestDaemon(), cli: .recordingForTests(runner: recorder), activitySource: activitySource,
            defaults: LeoInMemoryDefaults(), templateFetchRunner: LeoRecordingTemplateRunner(), machineRunner: LeoRecordingTemplateRunner(),
            chatClient: FakeChatClient()
        )
        defer { runtime.shutdown() }

        runtime.machines.start(flavor: .socketEvents)

        await awaitCondition(timeout: 5, message: "localhost's templates never loaded") {
            await runtime.actions.templateList(for: .local) == .loaded([LeoTemplate(name: "local-template")])
        }
        let calls = await recorder.calls
        #expect(calls == [.init(executable: "/leo", arguments: ["template", "list", "--json"])], "one CLI template fetch, got \(calls)")
    }
}

actor RuntimeTestDaemon: LeoDaemonClient {
    private(set) var listCallCount = 0
    private(set) var startCalls: [String] = []

    func listAgents() async throws -> [LeoAgent] { listCallCount += 1; return [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { startCalls.append(name) }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}
