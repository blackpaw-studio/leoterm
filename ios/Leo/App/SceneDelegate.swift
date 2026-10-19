import ComposableArchitecture
import LeoFeatures
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = Self.rootViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    private static func rootViewController() -> UIViewController {
        #if DEBUG
        if let fixture = ChatQuestionsFixture.requested { return ChatQuestionsFixture.rootViewController(for: fixture) }
        #endif
        return RootSplitViewController(store: AppDelegate.store)
    }

    // Event streams run only in the foreground; push covers the background.
    func sceneDidBecomeActive(_ scene: UIScene) {
        AppDelegate.store.send(.scenePhaseChanged(isActive: true))
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        AppDelegate.store.send(.scenePhaseChanged(isActive: false))
    }
}
