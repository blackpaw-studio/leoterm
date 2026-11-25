import ComposableArchitecture
import Foundation
import LeoKit

/// Keeps the inbox's local seen marks (hosts whose daemon has no synced
/// `seen` route) across launches. The marks are not secrets.
@DependencyClient
public struct InboxSeenStoreClient: Sendable {
    public var load: @Sendable () -> LeoInboxSeenState = { LeoInboxSeenState() }
    public var save: @Sendable (_ state: LeoInboxSeenState) -> Void
}

extension InboxSeenStoreClient: DependencyKey {
    public static let testValue = InboxSeenStoreClient()

    public static var liveValue: InboxSeenStoreClient {
        let key = "leo.inbox.seen"
        return InboxSeenStoreClient(
            load: {
                UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LeoInboxSeenState.self, from: $0) } ?? LeoInboxSeenState()
            },
            save: { state in
                guard let data = try? JSONEncoder().encode(state) else { return }
                UserDefaults.standard.set(data, forKey: key)
            }
        )
    }
}

extension DependencyValues {
    public var inboxSeenStore: InboxSeenStoreClient {
        get { self[InboxSeenStoreClient.self] }
        set { self[InboxSeenStoreClient.self] = newValue }
    }
}
