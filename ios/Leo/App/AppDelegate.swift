import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UserNotifications

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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-exportPushKey") { Self.exportPushKey() }
        #endif
        // Before returning, so a tap that launched the app is delivered.
        UNUserNotificationCenter.current().delegate = self
        Self.registerChatCategories()
        // Previews are temporary; anything left from a previous run goes.
        @Dependency(\.surfacedFiles) var surfacedFiles
        surfacedFiles.discardAll()
        Self.store.send(.task)
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// The reply and permission categories. `ask` categories are per choice
    /// set; the notification extension adds those as pushes arrive.
    private static func registerChatCategories() {
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            let fixed = LeoChatNotificationActions.staticCategories.map(\.notificationCategory)
            let asks = existing.filter { $0.identifier.hasPrefix(LeoChatNotificationActions.askCategoryPrefix) }
            UNUserNotificationCenter.current().setNotificationCategories(Set(fixed).union(asks))
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.store.send(.push(.tokenReceived(deviceToken)))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.store.send(.push(.remoteNotificationsFailed(error.localizedDescription)))
    }

    /// UI tests start from no paired daemons and no opened files.
    private static func resetForUITests() {
        @Dependency(\.pairedDaemons) var pairedDaemons
        @Dependency(\.secrets) var secrets
        for daemon in (try? pairedDaemons.load()) ?? [] { try? secrets.delete(daemon.id) }
        try? pairedDaemons.save([])
        @Dependency(\.seenFiles) var seenFiles
        seenFiles.save(LeoSurfacedFileLedger())
    }

    #if DEBUG
    /// Debug builds only: writes the push key (base64) to
    /// `Library/Caches/leo-push-key.txt` in the app's data container, so a
    /// simulator test can seal a real push for `xcrun simctl push`.
    private static func exportPushKey() {
        @Dependency(\.pushClient) var pushClient
        guard let key = try? pushClient.key(), let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? Data(key.base64.utf8).write(to: caches.appending(path: "leo-push-key.txt"), options: .completeFileProtection)
    }
    #endif
}

extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    /// In the foreground the banner still shows (the agent may be on
    /// another daemon than the one on screen), except a chat push for the
    /// thread that is on screen: the message is already there.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if LeoPushNotification.isChat(userInfo: userInfo), let target = LeoPushNotification.target(userInfo: userInfo),
           Self.store.state.isChatOnScreen(AgentRef(daemonID: target.daemonID, name: target.agent)) {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let action = LeoChatNotificationActions.response(
            actionIdentifier: response.actionIdentifier, userText: (response as? UNTextInputNotificationResponse)?.userText, userInfo: userInfo
        ) {
            // Background actions: hold the completion until the daemon has it.
            nonisolated(unsafe) let completion = completionHandler
            Task { @MainActor in
                await Self.store.send(.chatNotificationAction(action)).finish()
                completion()
            }
            return
        }
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let target = LeoPushNotification.target(userInfo: userInfo) else { return }
        let ref = AgentRef(daemonID: target.daemonID, name: target.agent)
        if LeoPushNotification.isChat(userInfo: userInfo) {
            Self.store.send(.chatNotificationOpened(ref))
            if Self.store.chat?.ref == ref { Self.rootViewController?.showSelectedAgent() }
            return
        }
        Self.store.send(.notificationOpened(ref))
        // Already the selection: on iPhone, bring it back on screen.
        if Self.store.detail?.ref == ref { Self.rootViewController?.showSelectedAgent() }
    }

    private static var rootViewController: RootSplitViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController as? RootSplitViewController }
            .first
    }
}
