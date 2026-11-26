import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

/// The Tasks screens on a navigation stack: the list's switches, and the
/// prompt screen's hold on the stack while its text is unsaved.
@MainActor
struct TaskScreensTests {
    private struct Rig {
        let store: StoreOf<TaskSettings>
        let navigation: UINavigationController
        let list: TasksViewController
        let fake: LeoFakeConfigClient
        let window: UIWindow
    }

    private static let daemon = PairedDaemon(
        id: "d-test", name: "test", baseURL: URL(string: "https://leo.example.com")!,
        urls: [], deviceID: "dev", pairedAt: Date(timeIntervalSince1970: 1_000)
    )

    private static func rig() throws -> Rig {
        let fake = try ConfigGolden.client(tasks: LeoFakeTaskData(prompts: ["heartbeat.md": "Check in.", "prompts/nightly.md": "Nightly."]))
        let connection = DaemonConnection(daemon: daemon, secrets: DaemonSecrets(token: "t"))
        let store = Store(initialState: TaskSettings.State(daemon: daemon, connection: connection)) {
            TaskSettings()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in LeoConfigRevisionTracker() }
            $0.continuousClock = ImmediateClock()
        }
        let list = TasksViewController(store: store)
        let navigation = UINavigationController(rootViewController: list)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.loadViewIfNeeded()
        list.loadViewIfNeeded()
        return Rig(store: store, navigation: navigation, list: list, fake: fake, window: window)
    }

    private static func openPrompt(_ rig: Rig) async {
        await settle { rig.store.collection.core.phase == .loaded }
        rig.store.send(.collection(.rowTapped("heartbeat")))
        await settle { rig.navigation.topViewController is ConfigItemViewController }
        rig.store.send(.pageOpened(.prompt))
        // The push is animated: until it ends the view has no window and no safe area.
        await settle {
            guard let prompt = rig.navigation.topViewController as? TaskPromptViewController else { return false }
            return rig.store.prompt.phase == .loaded && rig.navigation.transitionCoordinator == nil && prompt.view.window != nil
        }
    }

    private func enabledSwitch(for task: String, in rig: Rig) -> UISwitch? {
        let collectionView = rig.list.view.subviews.lazy.compactMap { $0.subviews.compactMap { $0 as? UICollectionView }.first }.first
        guard let collectionView else { return nil }
        return collectionView.visibleCells.lazy.compactMap { Self.find(in: $0, id: "tasks.enabled.\(task)") }.first
    }

    private static func find(in view: UIView, id: String) -> UISwitch? {
        if let toggle = view as? UISwitch, toggle.accessibilityIdentifier == id { return toggle }
        return view.subviews.lazy.compactMap { find(in: $0, id: id) }.first
    }

    @Test func eachRowHasItsEnabledSwitch() async throws {
        let rig = try Self.rig()
        await settle { enabledSwitch(for: "heartbeat", in: rig) != nil }

        #expect(enabledSwitch(for: "heartbeat", in: rig)?.isOn == true)
        #expect(enabledSwitch(for: "nightly", in: rig)?.isOn == false)
    }

    @Test func flippingASwitchWritesEnabledAlone() async throws {
        let rig = try Self.rig()
        await settle { enabledSwitch(for: "nightly", in: rig) != nil }
        let toggle = try #require(enabledSwitch(for: "nightly", in: rig))

        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        await settle { rig.store.toggleInFlightIsIdle && rig.store.collection.core.items.first { $0.name == "nightly" }?.values["enabled"]?.boolValue == true }

        let updates = await rig.fake.calls.filter { if case .update = $0 { true } else { false } }
        guard case .update(_, "nightly", let patch, _)? = updates.first else {
            Issue.record("expected an update, got \(updates)")
            return
        }
        #expect(patch == ["enabled": .bool(true)])
    }

    @Test func openingTheFormAndThePromptPushesThemInOrder() async throws {
        let rig = try Self.rig()
        await Self.openPrompt(rig)

        #expect(rig.navigation.viewControllers.map { String(describing: type(of: $0)) } == ["TasksViewController", "ConfigItemViewController", "TaskPromptViewController"])
    }

    @Test func theEditorStaysOutOfTheSideSafeAreaInLandscape() async throws {
        let rig = try Self.rig()
        await Self.openPrompt(rig)
        let prompt = try #require(rig.navigation.topViewController as? TaskPromptViewController)
        // A notch or Dynamic Island on the leading edge, the home indicator
        // side on the trailing one, as an iPhone held in landscape has.
        let sideInset: CGFloat = 60
        prompt.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: sideInset, bottom: 0, right: sideInset)
        prompt.view.setNeedsLayout()
        prompt.view.layoutIfNeeded()

        let textView = try #require(Self.findTextView(in: prompt.view, id: "task.prompt.text"))
        let editor = textView.convert(textView.bounds, to: prompt.view)
        let safe = prompt.view.safeAreaLayoutGuide.layoutFrame
        #expect(safe.minX >= sideInset)
        #expect(editor.minX >= safe.minX)
        #expect(editor.maxX <= safe.maxX)
    }

    /// B-459: the prompt arrives by an animated push, and its view only joins
    /// the window (and picks up the safe area) once that transition ends. The
    /// helper that opens it must not return before then, or a test measuring
    /// the safe area reads 0 on a loaded runner.
    @Test func openingThePromptReturnsOnlyOnceItsPushHasSettled() async throws {
        let rig = try Self.rig()
        await Self.openPrompt(rig)
        let prompt = try #require(rig.navigation.topViewController as? TaskPromptViewController)

        #expect(rig.navigation.transitionCoordinator == nil)
        #expect(prompt.view.window != nil)
    }

    private static func findTextView(in view: UIView, id: String) -> UITextView? {
        if let textView = view as? UITextView, textView.accessibilityIdentifier == id { return textView }
        return view.subviews.lazy.compactMap { findTextView(in: $0, id: id) }.first
    }

    @Test func aDirtyPromptIsHeldOnScreenAndBackAsks() async throws {
        let rig = try Self.rig()
        await Self.openPrompt(rig)
        let prompt = try #require(rig.navigation.topViewController as? TaskPromptViewController)
        rig.store.send(.promptTextChanged("typed"))
        await settle { rig.navigation.interactivePopGestureRecognizer?.isEnabled == false }

        // The system back button stays: nothing hides it or stands in for it.
        #expect(!prompt.navigationItem.hidesBackButton)
        #expect(prompt.navigationItem.leftBarButtonItems == nil)
        let detail = try #require(rig.navigation.viewControllers.first { $0 is ConfigItemViewController })
        #expect(detail.navigationItem.backBarButtonItem is NoHistoryBackBarButtonItem)
        #expect(rig.list.navigationItem.backBarButtonItem is NoHistoryBackBarButtonItem)
        let backAction = try #require(prompt.navigationItem.backAction)
        backAction.performWithSender(nil, target: nil)
        await settle { rig.store.promptLeave != nil }

        #expect(rig.store.promptLeave != nil)
        #expect(rig.navigation.topViewController === prompt)

        // On iPad the question is a popover, pointing at the back button.
        await settle { prompt.presentedViewController is UIAlertController }
        let dialog = try #require(prompt.presentedViewController as? UIAlertController)
        #expect(dialog.popoverPresentationController?.sourceView === rig.navigation.navigationBar)
    }

    @Test func aDirtyPromptPoppedWithoutAskingComesBack() async throws {
        let rig = try Self.rig()
        await Self.openPrompt(rig)
        let prompt = try #require(rig.navigation.topViewController as? TaskPromptViewController)
        rig.store.send(.promptTextChanged("typed"))

        rig.navigation.popViewController(animated: false)
        await settle { rig.navigation.topViewController is TaskPromptViewController }

        #expect(rig.navigation.topViewController === prompt)
        #expect(rig.store.prompt.text == "typed")
    }

    @Test func discardingTheDirtyPromptPopsBackToTheForm() async throws {
        let rig = try Self.rig()
        await Self.openPrompt(rig)
        rig.store.send(.promptTextChanged("typed"))
        rig.store.send(.promptBackTapped)
        await settle { rig.store.promptLeave != nil }

        rig.store.send(.promptLeave(.presented(.discard)))
        await settle { rig.navigation.topViewController is ConfigItemViewController }

        #expect(rig.navigation.topViewController is ConfigItemViewController)
        #expect(rig.store.prompt.phase == .idle)
    }
}

private extension StoreOf<TaskSettings> {
    var toggleInFlightIsIdle: Bool { state.toggles == LeoTaskToggleOverrides() }
}
