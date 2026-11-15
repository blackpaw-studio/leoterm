import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import UIKit

@testable import Leo

/// The Machines list hosted in a navigation controller over a real store, as the
/// app shows it: one connected machine with an agent and stats.
@MainActor
enum MachinesHost {
    struct Rig {
        let store: StoreOf<AppFeature>
        let navigation: UINavigationController
        let list: DaemonsViewController
        let window: UIWindow
    }

    static let daemon = PairedDaemon(
        id: "d-dionysus", name: "Dionysus", baseURL: URL(string: "http://10.0.2.10:8370")!,
        urls: [], deviceID: "dev", pairedAt: Date(timeIntervalSince1970: 1_000)
    )

    nonisolated static let stats = LeoMachineStats(
        sampledAt: Date(timeIntervalSince1970: 1_000),
        cpu: .init(percent: 41, cores: 8),
        memory: .init(usedBytes: 580, totalBytes: 1_000),
        disk: .init(path: "/state", usedBytes: 640, totalBytes: 1_000)
    )

    static func rig() -> Rig {
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
        guard let scene else { preconditionFailure("The hosted test app has no window scene") }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        return Rig(store: store, navigation: navigation, list: list, window: window)
    }

    /// Lets main-queue work (snapshot applies, observation) run until `condition`
    /// holds. Yields instead of sleeping, so it returns as soon as the work is done.
    static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 where !condition() { await pump() }
    }

    /// One non-blocking turn of the main run loop (layout, snapshot applies, observation).
    private static func pump() async {
        await Task.yield()
        turnRunLoop()
    }

    private static func turnRunLoop() {
        RunLoop.main.run(mode: .default, before: Date())
    }

    /// Lets already-queued main-queue work run.
    static func drain() async {
        for _ in 0..<20 { await pump() }
    }

    /// Selects the first row as a tap on it does.
    static func tapFirstRow(_ rig: Rig) {
        guard let collection = rig.list.view.subviews.compactMap({ $0 as? UICollectionView }).first else { return }
        collection.delegate?.collectionView?(collection, didSelectItemAt: IndexPath(item: 0, section: 0))
    }

    static func firstCell(_ rig: Rig) -> UICollectionViewCell? {
        rig.list.view.layoutIfNeeded()
        let collection = rig.list.view.subviews.compactMap { $0 as? UICollectionView }.first
        return collection?.cellForItem(at: IndexPath(item: 0, section: 0))
    }

    static func meterViews(in view: UIView) -> [UIView] {
        if let line = view as? MeterLineView {
            return line.subviews.compactMap { $0 as? UIStackView }.flatMap(\.arrangedSubviews)
        }
        return view.subviews.flatMap { meterViews(in: $0) }
    }

}
