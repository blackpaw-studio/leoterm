import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UserNotifications

extension PushClient: @retroactive DependencyKey {
    public static var liveValue: PushClient {
        let store = LeoPushSharedStore()
        return PushClient(
            authorization: {
                switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
                case .notDetermined: .notDetermined
                case .denied: .denied
                case .authorized, .provisional, .ephemeral: .authorized
                @unknown default: .denied
                }
            },
            requestAuthorization: {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            },
            registerForRemoteNotifications: {
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            },
            key: { try store.loadOrCreateKey() },
            sharePairedDaemons: { try store.savePairedDaemonIDs($0) }
        )
    }
}
