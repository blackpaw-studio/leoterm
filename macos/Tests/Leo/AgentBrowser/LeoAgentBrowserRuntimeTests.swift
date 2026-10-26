import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// The app's agent browsers wired to its machines: a connected machine's
/// session streams while its daemon advertises `client_tools` and the
/// Agent browser setting is on; a listing closes gone agents' browsers; the
/// setting off closes them all; a handoff notifies only while agent
/// notifications are on.
@MainActor
struct LeoAgentBrowserRuntimeTests {
    private static let dionysus = LeoHostID.remote("dionysus")
    private static let alpha = LeoAgentBrowserKey(host: dionysus, agent: "alpha")

    private final class FakePoster: LeoNotificationPosting {
        private(set) var posted: [LeoAttentionNotification] = []
        func requestAlertAuthorization() async -> Bool { true }
        func post(_ notification: LeoAttentionNotification) async { posted.append(notification) }
    }

    private final class Switch {
        var isOn = true
    }

    private let defaults = LeoInMemoryDefaults()
    private let client = FakeClientTools()
    private let poster = FakePoster()
    private let notifications = Switch()

    private func runtime() -> LeoAgentBrowserRuntime {
        LeoAgentBrowserRuntime(
            setting: LeoAgentBrowserSetting(defaults: defaults, isSupported: true),
            forwards: LeoMachinePortForwards(makeForwards: { _ in nil }),
            makeBrowser: { _ in FakeBrowserModel() },
            makeClient: { [client] _, _ in client },
            poster: poster, notificationsEnabled: { [notifications] in notifications.isOn }
        )
    }

    private static func row(_ name: String, _ status: LeoAgentStatus = .running) -> LeoAgentRow {
        LeoAgentRow(host: dionysus, name: name, template: nil, status: status, activity: .idle, actionDetail: nil)
    }

    private static func snapshot(
        rows: [LeoAgentRow] = [], features: [String] = ["client_tools"], listed: Bool = true,
        connectivity: LeoConnectivity = .connected
    ) -> LeoSidebarSnapshot {
        LeoSidebarSnapshot(
            rows: rows, connectivity: connectivity, generation: 1, listRefreshSucceeded: listed,
            features: LeoDaemonFeatures(features), featuresHost: dionysus
        )
    }

    /// Lets the runtime's tasks run until `condition` holds, without a clock.
    private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    /// Lets every pending task run, for checking that something didn't happen.
    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func connected(_ runtime: LeoAgentBrowserRuntime) async {
        runtime.machineConnected(Self.dionysus, socketPath: "/tmp/dionysus.sock")
        runtime.snapshotLanded(Self.snapshot(), for: Self.dionysus)
        await until { client.streams.count == 1 }
    }

    @Test func aMachineStreamsOnceItsDaemonAdvertisesClientTools() async {
        let runtime = runtime()
        defer { runtime.shutdown() }
        runtime.machineConnected(Self.dionysus, socketPath: "/tmp/dionysus.sock")
        await settle()
        #expect(client.streams.isEmpty)
        runtime.snapshotLanded(Self.snapshot(features: []), for: Self.dionysus)
        await settle()
        #expect(client.streams.isEmpty)

        runtime.snapshotLanded(Self.snapshot(), for: Self.dionysus)

        await until { client.streams.count == 1 }
    }

    @Test func aDisconnectEndsTheStreamAndAReconnectReopensItAtOnce() async {
        let runtime = runtime()
        defer { runtime.shutdown() }
        await connected(runtime)

        runtime.machineDisconnected(Self.dionysus)
        await until { client.endedStreams == 1 }
        runtime.machineConnected(Self.dionysus, socketPath: "/tmp/dionysus.sock")

        await until { client.streams.count == 2 }
    }

    @Test func aDisconnectKeepsTheMachinesBrowsers() async {
        let runtime = runtime()
        defer { runtime.shutdown() }
        await connected(runtime)
        _ = runtime.browsers.openBrowser(for: Self.alpha)

        runtime.machineDisconnected(Self.dionysus)
        runtime.snapshotLanded(
            Self.snapshot(connectivity: .disconnected(reason: "gone", isRetrying: false)), for: Self.dionysus
        )

        #expect(runtime.browsers.keys == [Self.alpha])
    }

    @Test func aListingClosesTheBrowsersOfAgentsThatWent() async {
        let runtime = runtime()
        defer { runtime.shutdown() }
        await connected(runtime)
        let beta = LeoAgentBrowserKey(host: Self.dionysus, agent: "beta")
        _ = runtime.browsers.openBrowser(for: Self.alpha)
        _ = runtime.browsers.openBrowser(for: beta)

        runtime.snapshotLanded(Self.snapshot(rows: [Self.row("alpha")], listed: false), for: Self.dionysus)
        #expect(runtime.browsers.keys == [Self.alpha, beta])

        runtime.snapshotLanded(Self.snapshot(rows: [Self.row("alpha")]), for: Self.dionysus)
        #expect(runtime.browsers.keys == [Self.alpha])
    }

    @Test func turningTheSettingOffEndsTheStreamAndClosesEveryBrowser() async {
        let runtime = runtime()
        defer { runtime.shutdown() }
        await connected(runtime)
        _ = runtime.browsers.openBrowser(for: Self.alpha)

        runtime.setting.isOn = false

        await until { client.endedStreams == 1 }
        #expect(runtime.browsers.keys.isEmpty)
        #expect(runtime.browsers.openBrowser(for: Self.alpha) == nil)

        runtime.setting.isOn = true

        await until { client.streams.count == 2 }
        #expect(runtime.browsers.openBrowser(for: Self.alpha) != nil)
    }

    @Test func aHandoffNotifiesOnlyWhileAgentNotificationsAreOn() async throws {
        let runtime = runtime()
        defer { runtime.shutdown() }
        let beta = LeoAgentBrowserKey(host: Self.dionysus, agent: "beta")
        let alpha = try #require(runtime.browsers.openBrowser(for: Self.alpha))
        let betaSource = try #require(runtime.browsers.openBrowser(for: beta))
        // The parked calls are never awaited, so a failure here can't hang the run.
        notifications.isOn = false
        let quiet = Task { await alpha.control.requestHandoff(requestID: "ctr_1", message: "Unheard") }
        defer { quiet.cancel() }
        await settle()
        #expect(poster.posted.isEmpty)

        notifications.isOn = true
        let heard = Task { await betaSource.control.requestHandoff(requestID: "ctr_2", message: "Log in please") }
        defer { heard.cancel() }

        await until { !poster.posted.isEmpty }
        #expect(poster.posted.map(\.body) == ["Log in please"])
    }
}
