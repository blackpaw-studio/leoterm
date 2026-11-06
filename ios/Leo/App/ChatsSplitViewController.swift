import ComposableArchitecture
import LeoFeatures
import UIKit

/// The Chats tab: the inbox beside the open thread.
final class ChatsSplitViewController: SelectionSplitViewController {
    private let store: StoreOf<AppFeature>

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(
            primary: ChatsViewController(store: store),
            placeholder: { NoSelectionViewController(.chat) },
            makeScreen: { _ in store.scope(state: \.chat, action: \.chat).map(ChatThreadViewController.init(store:)) },
            selectionPopped: { store.send(.chatPopped) }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe { [weak self] in
            guard let self else { return }
            select(store.chat?.ref)
        }
    }
}
