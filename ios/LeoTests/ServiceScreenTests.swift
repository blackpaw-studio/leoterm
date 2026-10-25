import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

/// The Service screen, and the machine-level restart question asked while a
/// pane covers the machine screen.
@MainActor
struct ServiceScreenTests {
    private struct Rig {
        let store: StoreOf<MachineSettings>
        let navigation: UINavigationController
        let fake: LeoFakeConfigClient
        let window: UIWindow
    }

    private static let daemon = PairedDaemon(
        id: "d-test", name: "test", baseURL: URL(string: "https://leo.example.com")!,
        urls: [], deviceID: "dev", pairedAt: Date(timeIntervalSince1970: 1_000)
    )

    private static func rig() async throws -> Rig {
        let fake = try ConfigGolden.client()
        await fake.setService(LeoFakeServiceState(
            version: "v0.59.0", pid: 42, processes: [LeoServiceProcess(name: "zeus", status: "running")], log: "daemon started\n"
        ))
        var session = DaemonSession(daemon: daemon)
        session.connection = .connected
        session.features = LeoDaemonFeatures(["config_api"])
        let store = Store(initialState: MachineSettings.State(link: MachineLink(session: session))) {
            MachineSettings()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in LeoConfigRevisionTracker() }
            $0.continuousClock = ImmediateClock()
        }
        let fleet = Store(initialState: Fleet.State(daemons: [daemon])) { Fleet() }
        let navigation = UINavigationController(rootViewController: MachineSettingsViewController(store: store, fleet: fleet))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.loadViewIfNeeded()
        navigation.viewControllers.first?.loadViewIfNeeded()
        return Rig(store: store, navigation: navigation, fake: fake, window: window)
    }

    private static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private static func openService(_ rig: Rig) async {
        rig.store.send(.rowTapped(.service))
        await settle { rig.navigation.topViewController is ServiceViewController }
    }

    @Test func theServiceScreenShowsTheStatusAndTheLog() async throws {
        let rig = try await Self.rig()
        await Self.openService(rig)
        let screen = try #require(rig.navigation.topViewController as? ServiceViewController)

        await Self.settle { rig.store.destination?.service?.status != .idle && rig.store.destination?.service?.logText == "daemon started\n" }

        #expect(rig.store.destination?.service?.logText == "daemon started\n")
        await Self.settle {
            screen.view.layoutIfNeeded()
            return screen.view.findLabel(text: "v0.59.0")
        }
        #expect(screen.view.findLabel(text: "v0.59.0"))
        #expect(screen.view.findLabel(text: "42"))
    }

    @Test func aRestartQuestionIsAskedOverThePaneThatIsShowing() async throws {
        let rig = try await Self.rig()
        await Self.openService(rig)

        rig.store.send(.restart(.requested(.agents)))
        await Self.settle { rig.navigation.presentedViewController is UIAlertController }

        let alert = try #require(rig.navigation.presentedViewController as? UIAlertController)
        #expect(alert.title == "Restart all agents on test?")
        #expect(alert.message == LeoServiceText.agentsRestartMessage(running: 1))
    }

    @Test func leavingTheServiceScreenStopsTheLogLoop() async throws {
        let rig = try await Self.rig()
        await Self.openService(rig)
        await Self.settle { rig.store.destination?.service?.isVisible == true }
        #expect(rig.store.destination?.service?.isVisible == true)

        rig.navigation.popViewController(animated: false)
        await Self.settle { rig.store.destination?.service?.isVisible != true }

        #expect(rig.store.destination?.service?.isVisible != true)
    }
}

private extension UIView {
    func findLabel(text: String) -> Bool {
        if let label = self as? UILabel, label.text == text { return true }
        return subviews.contains { $0.findLabel(text: text) }
    }
}
