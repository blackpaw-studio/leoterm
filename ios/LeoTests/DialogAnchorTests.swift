import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

/// An action sheet is a popover on iPad, and UIKit raises if it has nothing
/// to point at. Every settings sheet is anchored to the bar button it follows
/// from: Back for the leave questions, Save for the ones about a save.
@MainActor
struct DialogAnchorTests {
    private static let daemon = PairedDaemon(
        id: "d-test", name: "test", baseURL: URL(string: "https://leo.example.com")!,
        urls: [], deviceID: "dev", pairedAt: Date(timeIntervalSince1970: 1_000)
    )

    private static func sheet() -> UIAlertController {
        UIAlertController(title: "Question", message: nil, preferredStyle: .actionSheet)
    }

    private static func window(for root: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    private static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aSheetCanPointAtABarButton() {
        let item = UIBarButtonItem(title: "Save")

        let anchored = Self.sheet().anchored(to: item)

        #expect(anchored.popoverPresentationController?.barButtonItem === item)
    }

    @Test func aSheetPointsAtTheBackCornerOfTheBar() {
        let navigation = UINavigationController(rootViewController: UIViewController())
        _ = Self.window(for: navigation)

        let anchored = Self.sheet().anchoredToBack(of: navigation.topViewController!)

        #expect(anchored.popoverPresentationController?.sourceView === navigation.navigationBar)
        #expect(anchored.popoverPresentationController?.barButtonItem == nil)
    }

    @Test func aSheetWithoutABarStillPointsSomewhere() {
        let lone = UIViewController()
        lone.loadViewIfNeeded()

        let anchored = Self.sheet().anchoredToBack(of: lone)

        #expect(anchored.popoverPresentationController?.sourceView === lone.view)
    }

    @Test func theFileChangedQuestionPointsAtSave() async throws {
        let connection = DaemonConnection(daemon: Self.daemon, secrets: DaemonSecrets(token: "t"))
        var initial = TaskSettings.State(daemon: Self.daemon, connection: connection)
        initial.promptDialog = ConfirmationDialogState {
            TextState("This task now uses other.md")
        } actions: {
            ButtonState(action: .keepText) { TextState("Keep My Text") }
            ButtonState(role: .cancel) { TextState("Keep Editing") }
        }
        let store = Store(initialState: initial) { TaskSettings() }
        let prompt = TaskPromptViewController(store: store)
        let navigation = UINavigationController(rootViewController: UIViewController())
        let window = Self.window(for: navigation)
        navigation.pushViewController(prompt, animated: false)

        await Self.settle { navigation.presentedViewController is UIAlertController }

        let dialog = try #require(navigation.presentedViewController as? UIAlertController)
        #expect(dialog.popoverPresentationController?.barButtonItem === prompt.navigationItem.rightBarButtonItems?.first)
        withExtendedLifetime(window) {}
    }
}
