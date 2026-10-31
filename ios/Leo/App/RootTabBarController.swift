import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// The app's four tabs: Chats, Agents, Machines and Settings. It also hosts
/// everything presented over the whole app: pairing, appearance, the move
/// flow's prompts and progress.
final class RootTabBarController: UITabBarController, UITabBarControllerDelegate {
    @UIBindable private var store: StoreOf<AppFeature>
    private let chatsTab: UITab
    private var isShowingNamePrompt = false
    private lazy var moveProgress = MoveProgressView { [weak self] in self?.store.send(.move(.presented(.hideTapped))) }

    init(store: StoreOf<AppFeature>) {
        self.store = store
        chatsTab = Self.makeTab(.chats) { ChatsSplitViewController(store: store) }
        let tabs = [
            chatsTab,
            Self.makeTab(.agents) { AgentsSplitViewController(store: store) },
            Self.makeTab(.machines) {
                Self.navigation(DaemonsViewController(store: store.scope(state: \.daemons, action: \.daemons), fleet: store.scope(state: \.fleet, action: \.fleet)))
            },
            Self.makeTab(.settings) { Self.navigation(SettingsViewController(app: store)) },
        ]
        super.init(nibName: nil, bundle: nil)
        setTabs(tabs, animated: false)
        mode = .tabBar
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

        // The unread badge needs threads even before the Chats tab has been opened.
        store.send(.chatsEntryAppeared)
        observe { [weak self] in
            guard let self else { return }
            let unread = store.chats.unreadTotal
            chatsTab.badgeValue = unread > 0 ? "\(unread)" : nil
        }
        observe { [weak self] in
            guard let self else { return }
            showSelectedTab()
        }
    }

    // A selection made before the tab bar is on screen (a launch for a push tap) is dropped by UIKit, so it is applied again here.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        showSelectedTab()
    }

    private func showSelectedTab() {
        let identifier = store.selectedTab.identifier
        guard selectedTab?.identifier != identifier, let tab = tab(forIdentifier: identifier) else { return }
        selectedTab = tab
    }

    // Only the user's taps come through here, so the store's own selection never echoes back.
    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if let tab = AppTab(identifier: tab.identifier) { store.send(.tabSelected(tab)) }
        return true
    }

    private static func makeTab(_ tab: AppTab, root: @escaping () -> UIViewController) -> UITab {
        UITab(title: tab.title, image: UIImage(systemName: tab.symbol), identifier: tab.identifier) { _ in root() }
    }

    private static func navigation(_ root: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
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
}

private extension AppTab {
    var identifier: String {
        switch self {
        case .chats: "chats"
        case .agents: "agents"
        case .machines: "machines"
        case .settings: "settings"
        }
    }

    init?(identifier: String) {
        guard let tab = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = tab
    }

    var title: String {
        switch self {
        case .chats: String(localized: "Chats")
        case .agents: String(localized: "Agents")
        case .machines: String(localized: "Machines")
        case .settings: String(localized: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .agents: "person.crop.rectangle.stack"
        case .machines: "server.rack"
        case .settings: "gearshape"
        }
    }
}

/// B-324: while a move, copy or duplicate is in flight this sits over the whole
/// app, so the row menus, swipe actions and detail rows can't start a second
/// one, and says what is happening.
private final class MoveProgressView: UIView {
    private let label = UILabel()
    private let detail = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(onHide: @escaping () -> Void) {
        super.init(frame: .zero)
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
        detail.text = String(localized: "Leo keeps moving it in the background.")
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        detail.adjustsFontForContentSizeCategory = true
        var hide = UIButton.Configuration.plain()
        hide.title = String(localized: "Hide")
        let hideButton = UIButton(configuration: hide, primaryAction: UIAction { _ in onHide() })
        hideButton.accessibilityIdentifier = "agent.move.hide"
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label, detail, hideButton])
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
