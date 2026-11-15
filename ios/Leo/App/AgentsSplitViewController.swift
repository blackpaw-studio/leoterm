import ComposableArchitecture
import LeoFeatures
import UIKit

/// The Agents tab: the agents list beside the selected agent's detail.
final class AgentsSplitViewController: SelectionSplitViewController {
    private let store: StoreOf<AppFeature>

    init(store: StoreOf<AppFeature>) {
        self.store = store
        super.init(
            primary: AgentsViewController(store: store),
            placeholder: { NoSelectionViewController(.agent) },
            makeScreen: { _ in store.scope(state: \.detail, action: \.detail).map(AgentDetailViewController.init(store:)) },
            selectionPopped: { store.send(.detailPopped) }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe { [weak self] in
            guard let self else { return }
            select(store.detail?.ref)
        }
    }
}
