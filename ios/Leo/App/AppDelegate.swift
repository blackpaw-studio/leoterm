import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The one app store, shared with the scene.
    @MainActor static let store: StoreOf<AppFeature> = {
        LeoLog.subsystem = "studio.blackpaw.leo.ios"
        let deviceName = UIDevice.current.name
        prepareDependencies { $0.deviceName = deviceName }
        return Store(initialState: AppFeature.State()) { AppFeature() }
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-resetForUITests") { Self.resetForUITests() }
        // Previews are temporary; anything left from a previous run goes.
        @Dependency(\.surfacedFiles) var surfacedFiles
        surfacedFiles.discardAll()
        Self.store.send(.task)
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// UI tests start from no paired daemons.
    private static func resetForUITests() {
        @Dependency(\.pairedDaemons) var pairedDaemons
        @Dependency(\.secrets) var secrets
        for daemon in (try? pairedDaemons.load()) ?? [] { try? secrets.delete(daemon.id) }
        try? pairedDaemons.save([])
    }
}
