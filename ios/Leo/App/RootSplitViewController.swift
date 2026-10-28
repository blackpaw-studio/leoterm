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
    private var isShowingNamePrompt = false
    private let moveProgress = MoveProgressView()

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

        present(item: $store.scope(state: \.appearance, action: \.appearance)) { store in
            let navigation = UINavigationController(rootViewController: AgentAppearanceViewController(store: store))
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                #if DEBUG
                if AppearanceFixture.prefersLargeSheet { sheet.selectedDetentIdentifier = .large }
                #endif
            }
            return navigation
        }

        present(item: $store.scope(state: \.move?.confirmation, action: \.move.presented.confirmation)) { store in
            UIAlertController(store: store)
        }
        present(item: $store.scope(state: \.move?.alert, action: \.move.presented.alert)) { store in
            UIAlertController(store: store)
        }
        observe { [weak self] in
            guard let self else { return }
            presentNamePromptIfNeeded()
        }
        moveProgress.frame = view.bounds
        moveProgress.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(moveProgress)
        observe { [weak self] in
            guard let self else { return }
            moveProgress.show(store.move?.isMoving == true ? store.move : nil)
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

    /// B-324: a copy asks for an optional name. A text field can't be an
    /// `AlertState`, so the prompt is built here while the flow asks for it.
    private func presentNamePromptIfNeeded() {
        guard let flow = store.move, flow.isAskingName, !isShowingNamePrompt else { return }
        isShowingNamePrompt = true
        let prompt = UIAlertController(
            title: flow.intent == .duplicate ? String(localized: "Duplicate \(flow.agentName)") : String(localized: "Copy \(flow.agentName)"),
            message: String(localized: "Name the copy, or leave it blank to let the daemon pick one."),
            preferredStyle: .alert
        )
        prompt.addTextField { field in
            field.placeholder = "\(flow.agentName)-copy"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "agent.move.name"
        }
        prompt.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { [weak self] _ in
            self?.isShowingNamePrompt = false
            self?.store.send(.move(.presented(.nameCancelled)))
        })
        prompt.addAction(UIAlertAction(title: String(localized: "Copy"), style: .default) { [weak self] _ in
            self?.isShowingNamePrompt = false
            self?.store.send(.move(.presented(.nameSubmitted(prompt.textFields?.first?.text ?? ""))))
        })
        (presentedViewController ?? self).present(prompt, animated: true)
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

/// B-324: while a move, copy or duplicate is in flight this sits over the whole
/// app, so the row menus, swipe actions and detail rows can't start a second
/// one, and says what is happening.
private final class MoveProgressView: UIView {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        accessibilityIdentifier = "agent.move.progress"
        backgroundColor = UIColor.black.withAlphaComponent(0.25)
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.layer.cornerRadius = 14
        card.clipsToBounds = true
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ flow: AgentMove.State?) {
        isHidden = flow == nil
        guard let flow else { return }
        label.text = switch flow.intent {
        case .move(let host): String(localized: "Moving \(flow.agentName) to \(host)…")
        case .copy(let host): String(localized: "Copying \(flow.agentName) to \(host)…")
        case .duplicate: String(localized: "Duplicating \(flow.agentName)…")
        }
        UIAccessibility.post(notification: .announcement, argument: label.text)
    }
}
