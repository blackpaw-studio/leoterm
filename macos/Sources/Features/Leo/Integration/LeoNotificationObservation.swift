import Foundation

/// A block-based `NotificationCenter` observer that removes itself when
/// released, so its owner's lifetime bounds the observation.
final class LeoNotificationObservation {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, name: Notification.Name, handler: @escaping @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
    }

    deinit { center.removeObserver(token) }
}
