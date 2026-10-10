import Foundation
import Testing

@testable import Ghostty

/// B-270: an agent attached before its daemon's hello advertised
/// `attach_dispatch_placement` gets no `--dispatch-placement background`,
/// and the daemon then opens every dispatch of that agent as a pane. Once
/// the hello advertises it, those attaches are re-attached with the flag:
/// shown in place, hidden ones let go so their next show attaches anew.
@MainActor struct LeoAttachPlacementReattachTests {
    private static let placement = LeoDaemonFeatures(["attach_dispatch_placement"])
    private let worker = LeoAgentIdentity(host: .local, name: "worker")

    @Test func rowAttachedBeforeHelloIsReattachedWithPlacementOnceHelloAdvertisesIt() async throws {
        let host = FakeAttachContentHost()
        let features = FeatureBox()
        let coordinator = makeCoordinator(host: host, features: features)
        let origin = LeoWindowID()

        await coordinator.attach(identity: worker, from: origin, disposition: .content)
        let before = try #require(host.handles.first)
        host.focusedHandle = before
        features.byHost[.local] = Self.placement
        coordinator.daemonFeaturesChanged()

        #expect(host.reattachCalls.map(\.handle) == [before])
        #expect(host.reattachCalls.first?.command == "env -u TMUX -u TMUX_PANE '/leo' agent attach --dispatch-placement background -- 'worker'")
        let after = try #require(host.handles.last)
        #expect(after != before)
        #expect(coordinator.identity(forSurface: after.surfaceID) == worker)

        await coordinator.attach(identity: worker, from: origin, disposition: .content)
        #expect(host.contentCalls.count == 1)
        #expect(host.focused.last == after)
    }

    @Test func attachWaitingOnAConfirmWhenHelloLandsCarriesTheFlag() async {
        let host = FakeAttachContentHost()
        host.heldConfirmations = 1
        let features = FeatureBox()
        let coordinator = makeCoordinator(host: host, features: features)
        let origin = LeoWindowID()
        let worker = worker

        let task = Task { await coordinator.attach(identity: worker, from: origin, disposition: .content) }
        await waitUntil { host.pendingConfirmationCount == 1 }
        features.byHost[.local] = Self.placement
        host.resumeConfirmation(true)
        await task.value

        #expect(host.contentCalls.last?.command == "env -u TMUX -u TMUX_PANE '/leo' agent attach --dispatch-placement background -- 'worker'")
    }

    @Test func hiddenAttachFromBeforeHelloIsLetGoSoItsNextShowCarriesTheFlag() async throws {
        let host = FakeAttachContentHost()
        let features = FeatureBox()
        let coordinator = makeCoordinator(host: host, features: features)
        let origin = LeoWindowID()
        let other = LeoAgentIdentity(host: .local, name: "other")

        await coordinator.attach(identity: worker, from: origin, disposition: .content)
        await coordinator.attach(identity: other, from: origin, disposition: .content)
        let (hidden, shown) = (host.handles[0], host.handles[1])
        #expect(host.isHidden(hidden))
        features.byHost[.local] = Self.placement
        coordinator.daemonFeaturesChanged()

        #expect(host.releasedPooledSurfaces == [hidden])
        #expect(host.reattachCalls.map(\.handle) == [shown])
        await coordinator.attach(identity: worker, from: origin, disposition: .content)
        #expect(host.contentCalls.count == 3)
        #expect(host.contentCalls.last?.command == "env -u TMUX -u TMUX_PANE '/leo' agent attach --dispatch-placement background -- 'worker'")
    }

    @Test func sweepIsIdempotentAndSkipsAttachesThatAlreadyCarryTheFlag() async {
        let host = FakeAttachContentHost()
        let features = FeatureBox()
        let coordinator = makeCoordinator(host: host, features: features)
        let early = LeoAgentIdentity(host: .local, name: "early")
        let late = LeoAgentIdentity(host: .local, name: "late")

        await coordinator.attach(identity: early, from: LeoWindowID(), disposition: .content)
        let earlyHandle = host.handles[0]
        features.byHost[.local] = Self.placement
        await coordinator.attach(identity: late, from: LeoWindowID(), disposition: .content)
        coordinator.daemonFeaturesChanged()
        coordinator.daemonFeaturesChanged()

        #expect(host.reattachCalls.map(\.handle) == [earlyHandle])
    }

    @Test func onlyTheAdvertisingHostsAttachesAreReattached() async {
        let host = FakeAttachContentHost()
        let features = FeatureBox()
        let coordinator = makeCoordinator(host: host, features: features)
        let remote = LeoAgentIdentity(host: .remote("box"), name: "far")

        await coordinator.attach(identity: worker, from: LeoWindowID(), disposition: .content)
        await coordinator.attach(identity: remote, from: LeoWindowID(), disposition: .content)
        let (localHandle, remoteHandle) = (host.handles[0], host.handles[1])
        #expect(host.contentCalls[1].command == "ssh box leo agent attach -- far")

        features.byHost[.local] = Self.placement
        coordinator.daemonFeaturesChanged()
        #expect(host.reattachCalls.map(\.handle) == [localHandle])

        features.byHost = [.remote("box"): Self.placement]
        coordinator.daemonFeaturesChanged()
        #expect(host.reattachCalls.map(\.handle) == [localHandle, remoteHandle])
        #expect(host.reattachCalls.last?.command == "ssh box leo agent attach --dispatch-placement background -- far")
    }

    @Test func dispatchAndExitedAttachesAreLeftAlone() async {
        let host = FakeAttachContentHost()
        let features = FeatureBox()
        let coordinator = makeCoordinator(host: host, features: features)

        await coordinator.attach(identity: .dispatch(host: .local, id: "d-1", title: "sub"), from: LeoWindowID(), disposition: .content)
        await coordinator.attach(identity: worker, from: LeoWindowID(), disposition: .content)
        await host.emitAndWait(.processExited(host.handles[1]))
        features.byHost[.local] = Self.placement
        coordinator.daemonFeaturesChanged()

        #expect(host.reattachCalls.isEmpty)
        #expect(host.releasedPooledSurfaces.isEmpty)
    }

    @Test func failedReattachIsReportedOnceAndKeepsTheOldAttach() async throws {
        let host = FakeAttachContentHost()
        host.reattachError = FakeReattachError.failed
        let features = FeatureBox()
        var errors: [LeoAttachError] = []
        let coordinator = makeCoordinator(host: host, features: features) { errors.append($0) }

        await coordinator.attach(identity: worker, from: LeoWindowID(), disposition: .content)
        let handle = try #require(host.handles.first)
        features.byHost[.local] = Self.placement
        coordinator.daemonFeaturesChanged()
        coordinator.daemonFeaturesChanged()

        #expect(host.reattachCalls.count == 1)
        #expect(errors.map(\.identity) == [worker])
        #expect(host.isOpen(handle))
        #expect(coordinator.identity(forSurface: handle.surfaceID) == worker)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    /// Builds remote commands as `LeoRuntime` does: from the same features
    /// the coordinator reads.
    private func makeCoordinator(
        host: FakeAttachContentHost,
        features: FeatureBox,
        report: @escaping (LeoAttachError) -> Void = { _ in }
    ) -> LeoAttachCoordinator {
        LeoAttachCoordinator(
            host: host,
            executable: { "/leo" },
            remoteCommandBuilder: { identity in
                guard case .remote(let name) = identity.host else { throw FakeReattachError.failed }
                let flags = features.features(for: identity.host).attachPlacementArguments
                return (["ssh", name, "leo", "agent", "attach"] + flags + ["--", identity.name]).joined(separator: " ")
            },
            daemonFeatures: { features.features(for: $0) },
            report: report,
            lifecycleEventHandled: { host.acknowledge($0) }
        )
    }
}

/// What each host's daemon has advertised so far; a test turns a hello on.
private final class FeatureBox {
    var byHost: [LeoHostID: LeoDaemonFeatures] = [:]

    func features(for host: LeoHostID) -> LeoDaemonFeatures { byHost[host] ?? .none }
}
