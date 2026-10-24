import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

/// The editor's hold on the navigation stack: pushed while an item is open,
/// and not left by back or swipe while its edits are unsaved.
@MainActor
struct ConfigEditorNavigationTests {
    private struct Rig {
        let store: StoreOf<ConfigCollection>
        let navigation: UINavigationController
        let window: UIWindow
    }

    private static let daemon = PairedDaemon(
        id: "d-test", name: "test", baseURL: URL(string: "https://leo.example.com")!,
        urls: [], deviceID: "dev", pairedAt: Date(timeIntervalSince1970: 1_000)
    )

    private static func rig() throws -> Rig {
        let fake = try ConfigGolden.client()
        let connection = DaemonConnection(daemon: daemon, secrets: DaemonSecrets(token: "t"))
        let store = Store(initialState: ConfigCollection.State(resource: "templates", daemon: daemon, connection: connection)) {
            ConfigCollection()
        } withDependencies: {
            $0.configClients.client = { _ in fake }
            $0.configClients.revisions = { _ in LeoConfigRevisionTracker() }
        }
        let navigation = UINavigationController(rootViewController: ConfigCollectionViewController(store: store))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.loadViewIfNeeded()
        navigation.viewControllers.first?.loadViewIfNeeded()
        return Rig(store: store, navigation: navigation, window: window)
    }

    /// Waits for effects that finish on another thread; returns as soon as `condition` holds.
    private static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func openingAnItemPushesItsEditorAndClosingItPopsBack() async throws {
        let rig = try Self.rig()
        await Self.settle { rig.store.core.phase == .loaded }

        rig.store.send(.rowTapped("coder"))
        await Self.settle { rig.navigation.topViewController is ConfigItemViewController }
        #expect(rig.navigation.topViewController is ConfigItemViewController)

        rig.store.send(.backTapped)
        await Self.settle { rig.navigation.topViewController is ConfigCollectionViewController }
        #expect(rig.navigation.topViewController is ConfigCollectionViewController)
    }

    @Test func backWithUnsavedEditsAsksAndKeepsTheEditorOnScreen() async throws {
        let rig = try Self.rig()
        await Self.settle { rig.store.core.phase == .loaded }
        rig.store.send(.rowTapped("coder"))
        await Self.settle { rig.navigation.topViewController is ConfigItemViewController }
        let editor = try #require(rig.navigation.topViewController as? ConfigItemViewController)
        rig.store.send(.field("model", .string("sonnet")))
        await Self.settle { rig.navigation.interactivePopGestureRecognizer?.isEnabled == false }

        let backAction = try #require(editor.navigationItem.backAction)
        backAction.performWithSender(nil, target: nil)
        await Self.settle { rig.store.leaveDialog != nil }

        #expect(rig.store.leaveDialog != nil)
        #expect(rig.navigation.topViewController === editor)
        #expect(rig.navigation.interactivePopGestureRecognizer?.isEnabled == false)
    }

    @Test func discardingFromTheQuestionPopsBackWithTheEditsGone() async throws {
        let rig = try Self.rig()
        await Self.settle { rig.store.core.phase == .loaded }
        rig.store.send(.rowTapped("coder"))
        await Self.settle { rig.navigation.topViewController is ConfigItemViewController }
        rig.store.send(.field("model", .string("sonnet")))
        rig.store.send(.backTapped)
        await Self.settle { rig.store.leaveDialog != nil }

        rig.store.send(.leaveDialog(.presented(.discard)))
        await Self.settle { rig.navigation.topViewController is ConfigCollectionViewController }

        #expect(rig.navigation.topViewController is ConfigCollectionViewController)
        #expect(rig.store.core.selection == nil)
        #expect(!rig.store.core.isDirty)
    }
}
