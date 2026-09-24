import AppKit
import Foundation
import Testing

@testable import Ghostty

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

    @Test func thePaletteShowsTheDisconnectedStateInsteadOfAttachableRows() {
        var retried = false
        let model = LeoAgentPaletteModel(retry: { retried = true })
        model.update(
            snapshot: LeoSidebarSnapshot(rows: [Self.alpha], connectivity: .disconnected(reason: "Connection closed", isRetrying: false), generation: 3),
            selectedHost: .local,
            hostState: .connected(socketPath: "/tmp/leo.sock")
        )

        #expect(model.rows == [.status(text: "Disconnected from localhost", hint: "Connection closed", canRetry: true), .newAgent, .plainShell])
        #expect(model.confirm() == nil)
        model.retryConnection()
        #expect(retried)
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

        #expect(model.rows.first == .status(text: LeoSFTPServerText.sanitized(message), hint: LeoSFTPServerText.sanitized(hint), canRetry: true))
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
        model.receive(LeoSidebarSnapshot(rows: [Self.alpha], connectivity: .disconnected(reason: "x", isRetrying: false), generation: 1))
        model.selection = Self.alpha.id

        #expect(model.isDisconnected)
        #expect(model.actionableSelection == nil)
        model.requestAttach(Self.alpha, from: LeoWindowID(), disposition: .reuseOrTab)
        #expect(attached.isEmpty)

        model.receive(LeoSidebarSnapshot(rows: [Self.alpha], connectivity: .connected, generation: 2))
        #expect(!model.isDisconnected)
        #expect(model.actionableSelection == Self.alpha)
        model.requestAttach(Self.alpha, from: LeoWindowID(), disposition: .reuseOrTab)
        #expect(attached == ["alpha"])
    }

    // MARK: Wake

    @Test func wakeRunsExactlyOneLivenessCheckAndAFailureDisconnects() async throws {
        let daemon = WakeDaemon(failAfter: 1)
        let center = NotificationCenter()
        let defaults = try #require(UserDefaults(suiteName: "LeoDisconnectedStateTests.\(UUID().uuidString)"))
        let runtime = LeoRuntime(
            daemon: daemon, cli: LeoCLI(),
            activitySource: .init(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            defaults: defaults, wakeNotifications: center
        )
        let session = runtime.makeWindowSession()
        session.setSidebarVisible(true)
        runtime.start()
        await awaitCondition(timeout: 5) { await runtime.model.snapshot.connectivity == .connected }
        let calls = await daemon.listCallCount

        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        await awaitCondition(timeout: 5) {
            if case .disconnected = await runtime.model.snapshot.connectivity { return true }
            return false
        }
        #expect(await daemon.listCallCount == calls + 1)
        #expect(runtime.model.snapshot.rows.map(\.name) == ["alpha"])
        runtime.shutdown()
    }

    // MARK: DEBUG fixture

    #if DEBUG
    @Test func theForcedDisconnectFixtureReadsItsEnvironmentKey() {
        #expect(LeoForcedDisconnectFixture.reason(environment: [LeoForcedDisconnectFixture.environmentKey: "1"]) != nil)
        #expect(LeoForcedDisconnectFixture.reason(environment: [:]) == nil)
        #expect(LeoForcedDisconnectFixture.reason(environment: [LeoForcedDisconnectFixture.environmentKey: "0"]) == nil)
    }

    @Test func theForcedDisconnectFixtureDisconnectsOnceAfterTheFirstList() async throws {
        let model = LeoSidebarModel()
        let requests = ForcedRequests()
        let arming = LeoForcedDisconnectFixture.arm(model: model, reason: "Forced") { reason in
            Task { await requests.append(reason) }
        }

        model.receive(LeoSidebarSnapshot(rows: [], connectivity: .loading, generation: 1))
        model.receive(LeoSidebarSnapshot(rows: [Self.alpha], connectivity: .connected, generation: 2))
        model.receive(LeoSidebarSnapshot(rows: [Self.alpha], connectivity: .connected, generation: 3))

        await awaitCondition { await requests.values == ["Forced"] }
        for _ in 0..<20 { await Task.yield() }
        #expect(await requests.values == ["Forced"], "only the first live list is forced down")
        withExtendedLifetime(arming) {}
    }
    #endif
}

private actor ForcedRequests {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

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
