import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// Agents list beside the selected agent or chat thread. On iPhone
/// (compact width) the split view collapses the two into one navigation
/// stack.
final class RootSplitViewController: UISplitViewController, UISplitViewControllerDelegate, UINavigationControllerDelegate {
    /// What the secondary column shows.
    private enum Secondary: Equatable {
        case chat(AgentRef)
        case detail(AgentRef)
    }

    @UIBindable private var store: StoreOf<AppFeature>
    private let agentsNavigation: UINavigationController
    private var shownDetail: Secondary?
    /// The secondary column's navigation controller. On iPhone it is pushed
    /// onto `agentsNavigation` whole, so its absence there means the user
    /// popped back to the list.
    private var secondaryNavigation: UINavigationController?

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
        agentsNavigation.delegate = self
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
            let root: UIViewController
            if case .chat = secondary, let chatStore = store.scope(state: \.chat, action: \.chat) {
                root = ChatThreadViewController(store: chatStore)
            } else if let detailStore = store.scope(state: \.detail, action: \.detail) {
                root = AgentDetailViewController(store: detailStore)
            } else {
                root = NoSelectionViewController()
            }
            let previous = secondaryNavigation
            let navigation = UINavigationController(rootViewController: root)
            secondaryNavigation = navigation
            setViewController(navigation, for: .secondary)
            if secondary != nil {
                show(.secondary)
            } else if isCollapsed {
                popOff(previous)
            } else {
                show(.primary)
            }
        }
    }

    /// Drops a secondary screen still on the iPhone stack (the selection
    /// went away under it), back to whichever list screen is beneath. A user
    /// pop has already done this, and `show(.primary)` would pop further,
    /// past Chats.
    private func popOff(_ navigation: UINavigationController?) {
        let stack = agentsNavigation.viewControllers
        guard let navigation, let index = stack.firstIndex(of: navigation), index > 0 else { return }
        agentsNavigation.popToViewController(stack[index - 1], animated: true)
    }

    // On iPhone the selection lasts as long as its screen is on the stack:
    // popping back to the list clears it, so selecting the same agent again
    // shows it again.
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard isCollapsed else { return }
        dropReplacedSecondaries(from: navigationController)
        guard shownDetail != nil, let secondaryNavigation,
              !navigationController.viewControllers.contains(secondaryNavigation) else { return }
        store.send(.secondaryPopped)
    }

    /// Swapping the secondary (detail to chat) pushes the new one over the
    /// old, which would be where Back lands.
    private func dropReplacedSecondaries(from navigationController: UINavigationController) {
        let stack = navigationController.viewControllers
        let current = stack.filter { !($0 is UINavigationController) || $0 === secondaryNavigation }
        guard current.count < stack.count else { return }
        navigationController.setViewControllers(current, animated: false)
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
