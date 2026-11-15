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

    @Test func aTestHostEndpointHasNoLegacyWebAPI() {
        let endpoint = LeoLocalDaemon.resolve(isTestHost: true)
        #expect(!endpoint.readsLegacyWebConfig)
        #expect(!endpoint.socketPath.hasPrefix(NSHomeDirectory()))
        #expect(LeoLocalDaemon.observeConfig() == nil)
    }

    @Test func productionResolutionIsUnchanged() {
        #expect(LeoLocalDaemon.resolve(isTestHost: false) == LeoLocalDaemon.Endpoint(socketPath: Self.productionSocket, readsLegacyWebConfig: true))
    }

    @Test func theLegacyFallbackAsksTheInjectedConfigOnly() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var count: Int { lock.withLock { value } }
            func bump() { lock.withLock { value += 1 } }
        }
        let loads = Counter()
        let source = LeoRuntime.makeSocketOrLegacyActivitySource(
            socketPath: "/dev/null/x.sock", observeConfig: { loads.bump(); return nil }
        )

        let state = try await source.fetchState()

        #expect(state.agents.isEmpty)
        #expect(loads.count == 1)
    }
}
