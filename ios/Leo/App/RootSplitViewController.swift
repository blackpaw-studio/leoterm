import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// Agents list beside the selected agent or chat thread. On iPhone
/// (compact width) the split view collapses the two into one navigation
/// stack.
final class RootSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    /// What the secondary column shows.
    private enum Secondary: Equatable {
        case chat(AgentRef)
        case detail(AgentRef)
    }

    @UIBindable private var store: StoreOf<AppFeature>
    private let agentsNavigation: UINavigationController
    private var shownDetail: Secondary?

    init(store: StoreOf<AppFeature>) {
        self.store = store
        agentsNavigation = UINavigationController(rootViewController: AgentsViewController(store: store))
        super.init(style: .doubleColumn)
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        primaryBackgroundStyle = .sidebar
        setViewController(agentsNavigation, for: .primary)
        setViewController(UINavigationController(rootViewController: NoSelectionViewController()), for: .secondary)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()

        present(item: $store.scope(state: \.pairing, action: \.pairing)) { store in
            let navigation = UINavigationController(rootViewController: PairingViewController(store: store))
            navigation.modalPresentationStyle = .formSheet
            return navigation
        }

        observe { [weak self] in
            guard let self else { return }
            let secondary: Secondary? = store.chat.map { .chat($0.ref) } ?? store.detail.map { .detail($0.ref) }
            guard secondary != shownDetail else { return }
            shownDetail = secondary
            if case .chat = secondary, let chatStore = store.scope(state: \.chat, action: \.chat) {
                setViewController(UINavigationController(rootViewController: ChatThreadViewController(store: chatStore)), for: .secondary)
                show(.secondary)
            } else if let detailStore = store.scope(state: \.detail, action: \.detail) {
                let navigation = UINavigationController(rootViewController: AgentDetailViewController(store: detailStore))
                setViewController(navigation, for: .secondary)
                show(.secondary)
            } else {
                setViewController(UINavigationController(rootViewController: NoSelectionViewController()), for: .secondary)
                show(.primary)
            }
        }
    }

    /// Re-shows the selected agent (on iPhone, after the user went back).
    func showSelectedAgent() {
        show(.secondary)
    }

    // Launching on iPhone shows the list, not an empty detail.
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        shownDetail == nil ? .primary : proposedTopColumn
    }
}

/// The secondary column before any agent is selected.
final class NoSelectionViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "person.crop.rectangle.stack")
        configuration.text = String(localized: "No Agent Selected")
        configuration.secondaryText = String(localized: "Choose an agent to see its state and act on it.")
        contentUnavailableConfiguration = configuration
    }
}
