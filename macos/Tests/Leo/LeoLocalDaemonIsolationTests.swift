import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-322: the hosted test app must never reach the production daemon.
@MainActor struct LeoLocalDaemonIsolationTests {
    private static let productionSocket = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath

    @Test func theTestHostNeverResolvesTheProductionSocket() {
        #expect(LeoLocalDaemon.socketPath != Self.productionSocket)
        #expect(!LeoLocalDaemon.socketPath.hasPrefix(NSHomeDirectory()))
    }

    @Test func theAppsOwnRuntimeTalksToTheIsolatedSocket() throws {
        let runtime = try #require((NSApp.delegate as? AppDelegate)?.leoRuntime, "the test host has no LeoRuntime")
        let daemon = try #require(runtime.localDaemon as? LeoSocketDaemonClient)
        #expect(daemon.socketPath == LeoLocalDaemon.socketPath)
        #expect(runtime.machines.environment.localSocketPath == LeoLocalDaemon.socketPath)
        #expect(runtime.machines.environment.localSocketPath != Self.productionSocket)
    }
}
