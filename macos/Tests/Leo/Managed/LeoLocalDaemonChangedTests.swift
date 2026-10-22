import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The app restarting its own daemon reconnects This Mac only: a remote
/// machine's SSH tunnel and feed are left alone.
@Suite(.timeLimit(.minutes(1)))
@MainActor struct LeoLocalDaemonChangedTests {
    @Test func itReconnectsThisMacAndLeavesEveryRemoteMachineConnected() async throws {
        let defaults = LeoInMemoryDefaults()
        try LeoMachineRegistryTestSupport.save([LeoMachineRegistryTestSupport.host("work")], to: defaults)
        let tunnels = LeoFakeTunnels()
        tunnels.script("evan@work", .hangs)
        let directory = LeoMachineTunnelTestSupport.localSocketDirectory
        let runtime = LeoRuntime(
            daemon: RuntimeTestDaemon(), cli: .recordingForTests(),
            activitySource: LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner(),
            machineRunner: LeoFakeHomeRunner(stdout: "/home/evan"),
            machineLegacySocketDirectory: directory,
            machineControlSocketDirectory: directory,
            makeTunnel: tunnels.factory
        )
        defer { runtime.shutdown() }
        runtime.machines.start(flavor: .socketEvents)
        try await until { tunnels.all.count == 1 }
        let local = runtime.machines.generation(for: .local)
        let work = runtime.machines.generation(for: .remote("work"))

        runtime.localDaemonChanged()

        #expect(runtime.machines.generation(for: .local) > local)
        #expect(runtime.machines.generation(for: .remote("work")) == work)
        #expect(tunnels.all.count == 1, "work's tunnel was replaced")
        #expect(tunnels.all.first?.terminationCount == 0, "work's tunnel was torn down")
    }
}
