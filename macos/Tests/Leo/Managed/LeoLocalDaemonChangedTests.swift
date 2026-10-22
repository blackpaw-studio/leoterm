import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The app restarting its own daemon reconnects the sidebar only when the
/// selected host IS the local daemon: Retry on a remote host would tear
/// down its SSH tunnel and clear its feed.
@MainActor struct LeoLocalDaemonChangedTests {
    private func runtime(hosts: [LeoHostConfiguration] = []) throws -> LeoRuntime {
        let defaults = LeoInMemoryDefaults()
        defaults.set(try JSONEncoder().encode(hosts), forKey: LeoHostStore.key)
        let directory = LeoHostSelectionTestSupport.localSocketDirectory
        return LeoRuntime(
            daemon: RuntimeTestDaemon(), cli: .recordingForTests(),
            activitySource: LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner(),
            hostConnectionTransport: LeoAlwaysHealthyTransport(),
            hostSelectionRunner: LeoFakeHomeRunner(stdout: "/home/evan"),
            hostSelectionSSHExecutable: LeoTunnelTestSupport.fixtureURL(),
            hostSelectionLegacySocketDirectory: directory,
            hostSelectionControlSocketDirectory: directory
        )
    }

    @Test func aLocalSelectionReconnects() throws {
        let runtime = try runtime()
        var retries = 0
        runtime.model.retryRequested = { retries += 1 }

        runtime.localDaemonChanged()

        #expect(retries == 1)
    }

    @Test func aRemoteSelectionIsLeftConnected() throws {
        let runtime = try runtime(hosts: [
            LeoHostConfiguration(name: "work", sshTarget: "evan@work", remoteSocketPath: "/remote/leo.sock")
        ])
        runtime.hostSelection.select(.remote("work"))
        var retries = 0
        runtime.model.retryRequested = { retries += 1 }

        runtime.localDaemonChanged()

        #expect(runtime.hostSelection.selected == .remote("work"))
        #expect(retries == 0)
        runtime.shutdown()
    }
}
