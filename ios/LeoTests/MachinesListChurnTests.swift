import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

/// B-304: on a busy machine the fleet changes many times a second (agent
/// events), and each change used to rebuild every row's meters inside an
/// animated snapshot apply: the gauges jumped and a touch on the row was lost.
/// A row whose own content did not change is left alone.
@MainActor
struct MachinesListChurnTests {
    private struct Rig {
        let store: StoreOf<AppFeature>
        let navigation: UINavigationController
        let list: DaemonsViewController
        let window: UIWindow
    }

    private static let daemon = PairedDaemon(
        id: "d-dionysus", name: "Dionysus", baseURL: URL(string: "http://10.0.2.10:8370")!,
        urls: [], deviceID: "dev", pairedAt: Date(timeIntervalSince1970: 1_000)
    )

    private nonisolated static let stats = LeoMachineStats(
        sampledAt: Date(timeIntervalSince1970: 1_000),
        cpu: .init(percent: 41, cores: 8),
        memory: .init(usedBytes: 580, totalBytes: 1_000),
        disk: .init(path: "/state", usedBytes: 640, totalBytes: 1_000)
    )

    private static func rig() -> Rig {
        var state = AppFeature.State()
        state.fleet = Fleet.State(daemons: [daemon])
        state.fleet.isActive = true
        var session = state.fleet.sessions[0]
        session.connection = .connected
        session.features = LeoDaemonFeatures(["machine_stats"])
        session.agents = [Agent(name: "zeus", status: .running, template: "coding")]
        session.stats = stats
        state.fleet.sessions[0] = session
        let store = Store(initialState: state) {
            AppFeature()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.daemonClient.machineStats = { _ in stats }
        }
        let list = DaemonsViewController(
            store: store.scope(state: \.daemons, action: \.daemons),
            fleet: store.scope(state: \.fleet, action: \.fleet)
        )
        let navigation = UINavigationController(rootViewController: list)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        return Rig(store: store, navigation: navigation, list: list, window: window)
    }

    private static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private static func firstCell(_ rig: Rig) -> UICollectionViewCell? {
        rig.list.view.layoutIfNeeded()
        let collection = rig.list.view.subviews.compactMap { $0 as? UICollectionView }.first
        return collection?.cellForItem(at: IndexPath(item: 0, section: 0))
    }

    private static func meterViews(in view: UIView) -> [UIView] {
        if let line = view as? MeterLineView {
            return line.subviews.compactMap { $0 as? UIStackView }.flatMap(\.arrangedSubviews)
        }
        return view.subviews.flatMap { meterViews(in: $0) }
    }

    @Test func aFleetChangeThatLeavesTheRowAloneKeepsItsMeterViews() async throws {
        let rig = Self.rig()
        await Self.settle { !(Self.firstCell(rig).map { Self.meterViews(in: $0).isEmpty } ?? true) }
        let before = try #require(Self.firstCell(rig).map { Self.meterViews(in: $0) })
        try #require(!before.isEmpty)

        // An agent event: nothing the Machines row shows.
        rig.store.send(.fleet(.eventReceived(
            Self.daemon.id,
            .agentActivity(seq: 2, at: nil, agent: "zeus", activity: .working, currentAction: nil)
        )))
        try await Task.sleep(for: .milliseconds(100))
        let after = try #require(Self.firstCell(rig).map { Self.meterViews(in: $0) })

        #expect(after.count == before.count)
        #expect(zip(before, after).allSatisfy { $0 === $1 })
    }
}
