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
        /// A chat opened from its agent's detail, pushed over it.
        case chatOverDetail(AgentRef)
    }

    @UIBindable private var store: StoreOf<AppFeature>
    private let agentsNavigation: UINavigationController
    private var shownDetail: Secondary?
    /// The secondary column's navigation controller. On iPhone it is pushed
    /// onto `agentsNavigation` whole, so its absence there means the user
    /// popped back to the list.
    private var secondaryNavigation: UINavigationController?
    /// Rotations and window resizes in flight. Crossing the size class makes
    /// the split view take the secondary off the iPhone stack before
    /// `isCollapsed` flips, which is not the user popping back.
    private var transitionsInFlight = 0

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
            let secondary: Secondary? = switch (store.chat, store.detail) {
            case (let chat?, let detail?) where chat.ref == detail.ref: .chatOverDetail(chat.ref)
            case (let chat?, _): .chat(chat.ref)
            case (nil, let detail?): .detail(detail.ref)
            case (nil, nil): nil
            }
            guard secondary != shownDetail else { return }
            let previousSecondary = shownDetail
            shownDetail = secondary
            if let secondaryNavigation, moveWithinSecondary(secondaryNavigation, from: previousSecondary, to: secondary) { return }
            let previous = secondaryNavigation
            previous?.delegate = nil
            let navigation = UINavigationController()
            navigation.setViewControllers(makeSecondaryStack(secondary), animated: false)
            navigation.delegate = self
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

    /// The screens of the secondary column, bottom first.
    private func makeSecondaryStack(_ secondary: Secondary?) -> [UIViewController] {
        let detail = store.scope(state: \.detail, action: \.detail).map(AgentDetailViewController.init(store:))
        let chat = store.scope(state: \.chat, action: \.chat).map(ChatThreadViewController.init(store:))
        let stack: [UIViewController?] = switch secondary {
        case .chat: [chat]
        case .detail: [detail]
        case .chatOverDetail: [detail, chat]
        case nil: []
        }
        let screens = stack.compactMap { $0 }
        return screens.isEmpty ? [NoSelectionViewController()] : screens
    }

    /// Opening a detail's chat pushes it over the detail, and closing it pops
    /// back, inside the column that is already showing. A user's Back has
    /// popped it already, and an existing chat is not pushed twice. Anything
    /// else replaces the column.
    private func moveWithinSecondary(_ navigation: UINavigationController, from previous: Secondary?, to secondary: Secondary?) -> Bool {
        switch (previous, secondary) {
        case (.detail(let from), .chatOverDetail(let to)) where from == to:
            guard !navigation.viewControllers.contains(where: { $0 is ChatThreadViewController }),
                  let chatStore = store.scope(state: \.chat, action: \.chat) else { return false }
            navigation.pushViewController(ChatThreadViewController(store: chatStore), animated: true)
            return true
        case (.chatOverDetail(let from), .detail(let to)) where from == to:
            navigation.popToRootViewController(animated: true)
            return true
        default:
            return false
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

    override func willTransition(to newCollection: UITraitCollection, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.willTransition(to: newCollection, with: coordinator)
        trackTransition(coordinator)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        trackTransition(coordinator)
    }

    private func trackTransition(_ coordinator: any UIViewControllerTransitionCoordinator) {
        transitionsInFlight += 1
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.transitionsInFlight -= 1 }
    }

    // On iPhone the selection lasts as long as its screen is on the stack:
    // popping back to the list clears it, so selecting the same agent again
    // shows it again.
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard transitionsInFlight == 0 else { return }
        if navigationController === secondaryNavigation {
            // Back from a detail's chat leaves the detail selected.
            if case .chatOverDetail = shownDetail, !navigationController.viewControllers.contains(where: { $0 is ChatThreadViewController }) {
                store.send(.chatPopped)
            }
            return
        }
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
