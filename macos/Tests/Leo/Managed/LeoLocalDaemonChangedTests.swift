import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The app restarting its own daemon reconnects the sidebar only when the
/// selected host IS the local daemon: Retry on a remote host would tear
/// down its SSH tunnel and clear its feed.
@MainActor struct LeoLocalDaemonChangedTests {
    private func runtime(selectedHost: String?) -> LeoRuntime {
        let defaults = LeoInMemoryDefaults()
        if let selectedHost { defaults.set(selectedHost, forKey: "leo.selectedHost") }
        return LeoRuntime(
            daemon: RuntimeTestDaemon(), cli: .recordingForTests(),
            activitySource: LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner()
        )
    }

    @Test func aLocalSelectionReconnects() {
        let runtime = runtime(selectedHost: nil)
        var retries = 0
        runtime.model.retryRequested = { retries += 1 }

        runtime.localDaemonChanged()

        #expect(retries == 1)
    }

    @Test func aRemoteSelectionIsLeftConnected() {
        let runtime = runtime(selectedHost: "work")
        var retries = 0
        runtime.model.retryRequested = { retries += 1 }

        runtime.localDaemonChanged()

        #expect(runtime.hostSelection.selected == .remote("work"))
        #expect(retries == 0)
    }
}
