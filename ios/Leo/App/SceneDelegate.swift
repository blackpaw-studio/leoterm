import ComposableArchitecture
import LeoFeatures
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootSplitViewController(store: AppDelegate.store)
        window.makeKeyAndVisible()
        self.window = window
    }

    // Event streams run only in the foreground; push covers the background.
    func sceneDidBecomeActive(_ scene: UIScene) {
        AppDelegate.store.send(.scenePhaseChanged(isActive: true))
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        AppDelegate.store.send(.scenePhaseChanged(isActive: false))
    }
}
