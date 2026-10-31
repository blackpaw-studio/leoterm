import LeoFeatures
import UIKit

/// A list beside the selected item's screen. On iPhone (compact width) the
/// split view collapses the two into one navigation stack. Subclasses feed
/// it the store's selection through `select(_:)`.
class SelectionSplitViewController: UISplitViewController, UISplitViewControllerDelegate, UINavigationControllerDelegate {
    private let primaryNavigation: UINavigationController
    private let placeholder: () -> UIViewController
    private let makeScreen: (AgentRef) -> UIViewController?
    private let selectionPopped: () -> Void
    private var shownSelection: AgentRef?
    /// The secondary column's navigation controller. On iPhone it is pushed
    /// onto `primaryNavigation` whole, so its absence there means the user
    /// popped back to the list.
    private var secondaryNavigation: UINavigationController?
    /// Rotations and window resizes in flight. Crossing the size class makes
    /// the split view take the secondary off the iPhone stack before
    /// `isCollapsed` flips, which is not the user popping back.
    private var transitionsInFlight = 0

    /// `makeScreen` builds the selected item's screen; `selectionPopped` tells
    /// the store the user went back to the list.
    init(
        primary: UIViewController, placeholder: @escaping () -> UIViewController,
        makeScreen: @escaping (AgentRef) -> UIViewController?, selectionPopped: @escaping () -> Void
    ) {
        primaryNavigation = UINavigationController(rootViewController: primary)
        primaryNavigation.navigationBar.prefersLargeTitles = true
        self.placeholder = placeholder
        self.makeScreen = makeScreen
        self.selectionPopped = selectionPopped
        super.init(style: .doubleColumn)
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        primaryBackgroundStyle = .sidebar
        setViewController(primaryNavigation, for: .primary)
        setViewController(UINavigationController(rootViewController: placeholder()), for: .secondary)
        delegate = self
        primaryNavigation.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `selection`'s screen in the secondary column, or the placeholder
    /// (and the list, on iPhone) when nothing is selected.
    final func select(_ selection: AgentRef?) {
        guard selection != shownSelection else { return }
        shownSelection = selection
        let previous = secondaryNavigation
        previous?.delegate = nil
        let navigation = UINavigationController()
        navigation.setViewControllers([selection.flatMap(makeScreen) ?? placeholder()], animated: false)
        navigation.delegate = self
        secondaryNavigation = navigation
        setViewController(navigation, for: .secondary)
        if selection != nil {
            show(.secondary)
        } else if isCollapsed {
            popOff(previous)
        } else {
            show(.primary)
        }
    }

    /// Drops a secondary screen still on the iPhone stack (the selection
    /// went away under it), back to the list beneath. A user pop has already
    /// done this, and `show(.primary)` would pop further.
    private func popOff(_ navigation: UINavigationController?) {
        let stack = primaryNavigation.viewControllers
        guard let navigation, let index = stack.firstIndex(of: navigation), index > 0 else { return }
        primaryNavigation.popToViewController(stack[index - 1], animated: true)
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
    // popping back to the list clears it, so selecting the same item again
    // shows it again.
    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard transitionsInFlight == 0, navigationController !== secondaryNavigation, isCollapsed else { return }
        dropReplacedSecondaries(from: navigationController)
        guard shownSelection != nil, let secondaryNavigation,
              !navigationController.viewControllers.contains(secondaryNavigation) else { return }
        selectionPopped()
    }

    /// Swapping the secondary pushes the new one over the old, which would
    /// be where Back lands.
    private func dropReplacedSecondaries(from navigationController: UINavigationController) {
        let stack = navigationController.viewControllers
        let current = stack.filter { !($0 is UINavigationController) || $0 === secondaryNavigation }
        guard current.count < stack.count else { return }
        navigationController.setViewControllers(current, animated: false)
    }

    // Launching on iPhone shows the list, not an empty detail.
    func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
        shownSelection == nil ? .primary : proposedTopColumn
    }
}

/// The secondary column before anything is selected.
final class NoSelectionViewController: UIViewController {
    enum Kind {
        case agent, chat
    }

    private let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        switch kind {
        case .agent:
            configuration.image = UIImage(systemName: "person.crop.rectangle.stack")
            configuration.text = String(localized: "No Agent Selected")
            configuration.secondaryText = String(localized: "Choose an agent to see its state and act on it.")
        case .chat:
            configuration.image = UIImage(systemName: "bubble.left.and.bubble.right")
            configuration.text = String(localized: "No Chat Selected")
            configuration.secondaryText = String(localized: "Choose a conversation to read it and reply.")
        }
        contentUnavailableConfiguration = configuration
    }
}
