import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-007 / D-061 around the feed: the banner's words, the Reconnect menu
/// item, the palette, the sidebar model's inert rows, the wake check and
/// the DEBUG fixture that forces the state for screenshots.
@MainActor struct LeoDisconnectedStateTests {
    private static let alpha = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .unknown, actionDetail: nil)

    // MARK: Banner

    @Test func theBannerNamesTheHostTheWayTheHostPickerDoes() throws {
        let local = try #require(LeoDisconnectedBanner(host: .local, connectivity: .disconnected(reason: "Connection closed", isRetrying: false)))
        #expect(local.title == "Disconnected from localhost")
        #expect(local.reason == "Connection closed")
        #expect(!local.isRetrying)

        let remote = try #require(LeoDisconnectedBanner(host: .remote("mars"), connectivity: .disconnected(reason: "ssh exited (255)", isRetrying: true)))
        #expect(remote.title == "Disconnected from mars")
        #expect(remote.isRetrying)
    }

    /// The reason can be a remote ssh's stderr: it goes through the one
    /// sanitizer (B-020) when rendered.
    @Test func theReasonIsSanitized() throws {
        let raw = "ssh: connect\n\u{202E}refused\u{0007}   now"
        let banner = try #require(LeoDisconnectedBanner(host: .local, connectivity: .disconnected(reason: raw, isRetrying: false)))
        #expect(banner.reason == LeoSFTPServerText.sanitized(raw))
        #expect(!banner.reason.contains("\n"))
        #expect(!banner.reason.unicodeScalars.contains("\u{202E}"))
    }

    @Test func thereIsNoBannerUnlessDisconnected() {
        #expect(LeoDisconnectedBanner(host: .local, connectivity: .connected) == nil)
        #expect(LeoDisconnectedBanner(host: .local, connectivity: .loading) == nil)
        #expect(LeoDisconnectedBanner(host: .local, connectivity: .failed(message: "x")) == nil)
    }

    // MARK: Menu

    @Test func reconnectIsEnabledOnlyWhenThereIsSomethingToReconnect() {
        #expect(LeoMenuCommands.canReconnect(hasLeoSession: true, connectivity: .disconnected(reason: "x", isRetrying: false)))
        #expect(LeoMenuCommands.canReconnect(hasLeoSession: true, connectivity: .failed(message: "x")))
        #expect(!LeoMenuCommands.canReconnect(hasLeoSession: true, connectivity: .disconnected(reason: "x", isRetrying: true)))
        #expect(!LeoMenuCommands.canReconnect(hasLeoSession: true, connectivity: .connected))
        #expect(!LeoMenuCommands.canReconnect(hasLeoSession: true, connectivity: .loading))
        #expect(!LeoMenuCommands.canReconnect(hasLeoSession: false, connectivity: .disconnected(reason: "x", isRetrying: false)))
    }

    /// Q7: ⇧⌘R reconnects every machine that isn't connected, including one
    /// still connecting, but not one already retrying.
    @Test func reconnectTargetsEveryMachineThatIsNotConnected() {
        let machines: [(host: LeoHostID, connectivity: LeoConnectivity)] = [
            (.local, .connected),
            (.remote("a"), .failed(message: "refused")),
            (.remote("b"), .disconnected(reason: "x", isRetrying: false)),
            (.remote("c"), .disconnected(reason: "x", isRetrying: true)),
            (.remote("d"), .loading),
        ]

        #expect(LeoMenuCommands.machinesToReconnect(machines) == [.remote("a"), .remote("b"), .remote("d")])
        #expect(LeoMenuCommands.canReconnect(hasLeoSession: true, machines: machines))
        #expect(LeoMenuCommands.canReconnect(hasLeoSession: true, machines: [(.local, .connected), (.remote("d"), .loading)]))
        #expect(!LeoMenuCommands.canReconnect(hasLeoSession: true, machines: [(.local, .connected), (.remote("c"), .disconnected(reason: "x", isRetrying: true))]))
        #expect(!LeoMenuCommands.canReconnect(hasLeoSession: false, machines: machines))
    }

    /// Read from the xib source (instantiating MainMenu would also build
    /// its AppDelegate): Reconnect is ⇧⌘R and nothing else in the menu bar
    /// uses it. Ghostty's config keybinds don't bind ⇧⌘R on macOS either.
    @Test func theReconnectMenuItemHasAShortcutNoOtherMenuItemUses() throws {
        let items = try LeoMenuXib.shortcuts()
        let reconnect = try #require(items.first { $0.action == "reconnectLeo:" })
        #expect(reconnect.title == "Reconnect")
        #expect(reconnect.shortcut == "⇧⌘r")
        let clashes = items.filter { $0.action != "reconnectLeo:" && $0.shortcut == reconnect.shortcut }
        #expect(clashes.isEmpty, "\(clashes.map(\.title))")
    }

    // MARK: Palette

    @Test func thePaletteShowsTheDisconnectedStateInsteadOfAttachableRows() throws {
        var retried: [LeoHostID] = []
        let model = LeoAgentPaletteModel(retry: { retried.append($0) })
        model.update(
            snapshot: LeoSidebarSnapshot(rows: [Self.alpha], connectivity: .disconnected(reason: "Connection closed", isRetrying: false), generation: 3),
            selectedHost: .local,
            hostState: .connected(socketPath: "/tmp/leo.sock")
        )

        let banner = LeoDisconnectedBanner(host: .local, connectivity: .disconnected(reason: "Connection closed", isRetrying: false))
        #expect(model.rows == [.disconnected(host: .local, banner: try #require(banner)), .newAgent, .plainShell])
        #expect(model.confirm() == nil)
        model.retryConnection(.local)
        #expect(retried == [.local])
    }

    /// A remote tunnel's failure text is ssh's stderr: sanitized (B-020).
    @Test func thePaletteSanitizesATunnelFailure() {
        let message = "ssh: \u{202E}denied\nnow\u{0007}"
        let hint = "Run `ssh \u{202E}evil` once"
        let model = LeoAgentPaletteModel()
        model.update(
            snapshot: LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 0),
            selectedHost: .remote("mars"),
            hostState: .failed(message: message, hint: hint)
        )

        #expect(model.rows.first == .status(
            host: .remote("mars"), text: LeoSFTPServerText.sanitized(message), hint: LeoSFTPServerText.sanitized(hint), canRetry: true
        ))
    }

    /// The sidebar's full-panel failure (an initial remote connect that
    /// failed) shows ssh's stderr and a hint naming the configured target:
    /// both sanitized (B-020).
    @Test func theSidebarFailurePanelIsSanitized() {
        let message = "ssh: \u{202E}denied\nnow\u{0007}"
        let hint = "Run `ssh \u{202E}evil` once"
        let panel = LeoConnectionFailurePanel(message: message, hint: hint)
        #expect(panel.message == LeoSFTPServerText.sanitized(message))
        #expect(panel.hint == LeoSFTPServerText.sanitized(hint))
        #expect(LeoConnectionFailurePanel(message: "x", hint: nil).hint == nil)
    }

    // MARK: Sidebar model

    @Test func rowsAreInertWhileDisconnected() {
        let model = LeoSidebarModel()
        var attached: [String] = []
        model.attachRequested = { row, _, _ in attached.append(row.name) }
        model.receive(LeoSidebarSnapshot(rows: [Self.alpha], connectivity: .disconnected(reason: "x", isRetrying: false), generation: 1), for: .local)
        model.selection = Self.alpha.id

        #expect(model.isDisconnected(.local))
        #expect(model.actionableSelection == nil)
        model.requestAttach(Self.alpha, from: LeoWindowID(), disposition: .content)
        #expect(attached.isEmpty)

        model.receive(LeoSidebarSnapshot(rows: [Self.alpha], connectivity: .connected, generation: 2), for: .local)
        #expect(!model.isDisconnected(.local))
        #expect(model.actionableSelection == Self.alpha)
        model.requestAttach(Self.alpha, from: LeoWindowID(), disposition: .content)
        #expect(attached == ["alpha"])
    }

    // MARK: Wake

    @Test func wakeRunsExactlyOneLivenessCheckAndAFailureDisconnects() async throws {
        let daemon = WakeDaemon(failAfter: 1)
        let center = NotificationCenter()
        let defaults = LeoInMemoryDefaults()
        let runtime = LeoRuntime(
            daemon: daemon, cli: .recordingForTests(),
            activitySource: .init(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            defaults: defaults, templateFetchRunner: LeoRecordingTemplateRunner(), wakeNotifications: center,
            chatClient: FakeChatClient()
        )
        let session = runtime.makeWindowSession()
        session.setSidebarVisible(true)
        runtime.start()
        await awaitCondition(timeout: 5) { await runtime.model.snapshot(for: .local)?.connectivity == .connected }
        let calls = await daemon.listCallCount

        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        await awaitCondition(timeout: 5) {
            if case .disconnected? = await runtime.model.snapshot(for: .local)?.connectivity { return true }
            return false
        }
        #expect(await daemon.listCallCount == calls + 1)
        #expect(runtime.model.snapshot(for: .local)?.rows.map(\.name) == ["alpha"])
        runtime.shutdown()
    }

    // MARK: DEBUG fixture

    #if DEBUG
    @Test func theForcedDisconnectFixtureReadsItsEnvironmentKey() {
        #expect(LeoForcedDisconnectFixture.reason(environment: [LeoForcedDisconnectFixture.environmentKey: "1"]) != nil)
        #expect(LeoForcedDisconnectFixture.reason(environment: [:]) == nil)
        #expect(LeoForcedDisconnectFixture.reason(environment: [LeoForcedDisconnectFixture.environmentKey: "0"]) == nil)
    }

    /// Only the fixture's own drop is exempt from the automatic retry, so
    /// its banner stays up for screenshots.
    @Test func onlyTheFixturesOwnDropIsForced() {
        let forced = LeoForcedDisconnectFixture.forcedReason
        #expect(LeoForcedDisconnectFixture.isForced(.disconnected(reason: forced, isRetrying: false)))
        #expect(!LeoForcedDisconnectFixture.isForced(.disconnected(reason: "Connection closed", isRetrying: false)))
        #expect(!LeoForcedDisconnectFixture.isForced(.connected))
    }

    /// B-166: This Mac's feed can list on its own before the registry's
    /// first connect (generation 0). The force must wait for a registry
    /// connection's list: forced on the early one, that first connect reads
    /// as a Retry and reconnects, and the banner never shows.
    @Test func theForcedDisconnectHoldsWhenTheEarlyListLandsBeforeTheFirstConnect() async throws {
        let daemon = WakeDaemon(failAfter: .max)
        let (model, feeds, delivered) = Self.forcedFeeds(daemon: daemon)
        LeoForcedDisconnectFixture.arm(feeds: feeds, reason: LeoForcedDisconnectFixture.forcedReason)
        feeds.start(pollable: false)
        let feed = try #require(feeds.feed(for: .local))

        feeds.refresh()
        await awaitCondition { @MainActor in delivered.values.contains(.connected) }
        feeds.updateConnection(host: .local, generation: 1, phase: .connected(daemon: daemon, activitySource: Self.silentActivity()))
        await awaitCondition { await daemon.listCallCount == 2 }
        await awaitCondition { Self.isSettled(await feed.snapshot.connectivity) }
        await feed.drainEmissions()

        #expect(model.snapshot(for: .local)?.connectivity == Self.forcedDown)
    }

    @Test func theForcedDisconnectFiresOnceOnTheFirstConnectsListAndRetryReconnects() async throws {
        let daemon = WakeDaemon(failAfter: .max)
        let (model, feeds, delivered) = Self.forcedFeeds(daemon: daemon)
        LeoForcedDisconnectFixture.arm(feeds: feeds, reason: LeoForcedDisconnectFixture.forcedReason)
        feeds.start(pollable: false)
        let feed = try #require(feeds.feed(for: .local))

        feeds.updateConnection(host: .local, generation: 1, phase: .connected(daemon: daemon, activitySource: Self.silentActivity()))
        await awaitCondition { await daemon.listCallCount == 1 }
        await awaitCondition { await feed.snapshot.connectivity == Self.forcedDown }
        await feed.drainEmissions()
        #expect(model.snapshot(for: .local)?.connectivity == Self.forcedDown)

        // The header's Reconnect: the registry's next generation.
        feeds.updateConnection(host: .local, generation: 2, phase: .connected(daemon: daemon, activitySource: Self.silentActivity()))
        await awaitCondition { await daemon.listCallCount == 2 }
        await awaitCondition { await feed.snapshot.connectivity == .connected }
        await feed.drainEmissions()

        #expect(model.snapshot(for: .local)?.connectivity == .connected)
        #expect(delivered.forcedDrops == 1, "forced down once, not again on the Retry")
    }

    nonisolated private static let forcedDown = LeoConnectivity.disconnected(reason: LeoForcedDisconnectFixture.forcedReason, isRetrying: false)

    /// A list has landed on the connection: up, or forced down by it.
    nonisolated private static func isSettled(_ connectivity: LeoConnectivity) -> Bool {
        connectivity == .connected || connectivity == forcedDown
    }

    /// This Mac's feed wired to a sidebar model the way `LeoRuntime` wires
    /// it, not yet started, and every connectivity the model was handed.
    private static func forcedFeeds(daemon: any LeoDaemonClient) -> (LeoSidebarModel, LeoMachineFeeds, DeliveredConnectivity) {
        let model = LeoSidebarModel()
        model.setMachines([.local])
        let delivered = DeliveredConnectivity()
        let feeds = LeoMachineFeeds(dependencies: .init(
            localDaemon: daemon, localActivity: silentActivity(),
            onSnapshot: { host, snapshot in
                model.receive(snapshot, for: host)
                delivered.values.append(snapshot.connectivity)
            }
        ))
        feeds.setMachines([.local])
        return (model, feeds, delivered)
    }

    /// An activity stream that never sends and stays open.
    nonisolated private static func silentActivity() -> LeoSidebarActivitySource {
        LeoSidebarActivitySource(events: { AsyncStream { _ in } }, fetchState: { [] })
    }
    #endif
}

#if DEBUG
/// Every connectivity a sidebar model was handed, in order.
@MainActor private final class DeliveredConnectivity {
    var values: [LeoConnectivity] = []

    /// How many times the fixture's drop was entered from any other state.
    var forcedDrops: Int {
        zip([nil] + values.map(Optional.some), values).filter { previous, value in
            value == LeoConnectivity.disconnected(reason: LeoForcedDisconnectFixture.forcedReason, isRetrying: false)
                && !(previous.map(LeoForcedDisconnectFixture.isForced) ?? false)
        }.count
    }
}
#endif

/// Lists `alpha` for the first `failAfter` calls, then times out.
private actor WakeDaemon: LeoDaemonClient {
    private let failAfter: Int
    private(set) var listCallCount = 0

    init(failAfter: Int) { self.failAfter = failAfter }

    func listAgents() async throws -> [LeoAgent] {
        listCallCount += 1
        guard listCallCount <= failAfter else { throw LeoDaemonError.timeout }
        return [LeoAgent(name: "alpha", template: nil, repo: nil, workspace: nil, branch: nil, canonicalPath: nil, status: .running,
                         startedAt: nil, restarts: nil, stoppedReason: nil, wakeOnMessage: nil)]
    }

    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}
