import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// A machine's tasks: each row has its enabled switch and Run Now (swipe or
/// menu). Opening a row pushes the task's form; its Prompt and History rows
/// push their screens over it. Everything pushed stays pushed for as long as
/// the store says it is open (see `syncStack`).
final class TasksViewController: UIViewController, UICollectionViewDelegate {
    private enum Item: Hashable {
        case row(String)
        case loading
        case failed(String)
        case retry
        case empty
    }

    @UIBindable private var store: StoreOf<TaskSettings>
    private let banners = ConfigBannerStack()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private let addButton = UIBarButtonItem(systemItem: .add)
    private var editor: ConfigItemViewController?
    private var promptScreen: TaskPromptViewController?
    private var historyScreen: TaskHistoryViewController?
    private var logScreen: TaskLogViewController?

    private var collection: StoreOf<ConfigCollection> { store.scope(state: \.collection, action: \.collection) }

    init(store: StoreOf<TaskSettings>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Tasks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        addButton.primaryAction = UIAction(image: UIImage(systemName: "plus")) { [store] _ in store.send(.collection(.addTapped)) }
        addButton.accessibilityIdentifier = "tasks.add"
        addButton.accessibilityLabel = String(localized: "Add")
        navigationItem.rightBarButtonItem = addButton

        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "tasks.list"
        let stack = UIStackView(arrangedSubviews: [banners, collectionView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()

        present(item: $store.scope(state: \.collection.alert, action: \.collection.alert)) { store in
            UIAlertController(store: store)
        }
        present(item: $store.scope(state: \.collection.nameEntry, action: \.collection.nameEntry)) { store in
            let sheet = UINavigationController(rootViewController: NameEntryViewController(store: store))
            sheet.modalPresentationStyle = .formSheet
            return sheet
        }
        observe { [weak self] in self?.render() }
        store.send(.collection(.task))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncStack()
    }

    // MARK: rendering

    private func render() {
        let core = store.collection.core
        addButton.isEnabled = core.allows(.add)
        addButton.isHidden = !core.actions.contains(.add)
        banners.show(banners(for: store))

        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch core.phase {
        case .loading where core.items.isEmpty: snapshot.appendItems([.loading])
        case .failed(let message): snapshot.appendItems([.failed(message), .retry])
        default: snapshot.appendItems(core.items.isEmpty ? [.empty] : core.items.map { .row($0.name) })
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        syncStack()
    }

    private func banners(for store: StoreOf<TaskSettings>) -> [ConfigBanner] {
        var banners = ConfigBanners.banners(collection)
        if let message = store.message {
            banners.append(ConfigBanner(
                id: "task.message", style: .error, text: message, actions: [.init(title: "Dismiss") { store.send(.dismissMessage) }]
            ))
        }
        let dismiss = ConfigBanner.Action(title: "Dismiss") { store.send(.dismissRunNotice) }
        switch store.runNotice {
        case .starting(let name)?:
            banners.append(ConfigBanner(id: "task.run", style: .info, text: "Starting \(name)…"))
        case .started(let name)?:
            banners.append(ConfigBanner(id: "task.run", style: .info, text: "Started \(name). It shows under History when it finishes.", actions: [dismiss]))
        case .failed(let name, let reason)?:
            banners.append(ConfigBanner(id: "task.run", style: .error, text: "Couldn’t start \(name): \(reason)", actions: [dismiss]))
        case nil:
            break
        }
        return banners
    }

    // MARK: pushed screens

    /// What is pushed over the list follows the store: the open task's form,
    /// then the screen the page names. A dirty screen that was popped without
    /// asking (the system's back menu) comes back, so its text isn't lost.
    private func syncStack() {
        guard let navigation = navigationController, let index = navigation.viewControllers.firstIndex(of: self) else { return }
        let before = [editor, promptScreen, historyScreen, logScreen].compactMap { $0 as UIViewController? }
        let isOpen = store.collection.core.selection != nil
        editor = isOpen ? (editor ?? makeEditor()) : nil
        promptScreen = screen(promptScreen, wanted: isOpen && store.page == .prompt) { TaskPromptViewController(store: store) }
        historyScreen = screen(historyScreen, wanted: isOpen && [.history, .log].contains(store.page)) { TaskHistoryViewController(store: store) }
        logScreen = screen(logScreen, wanted: isOpen && store.page == .log) { TaskLogViewController(store: store) }
        let wanted = [editor, promptScreen, historyScreen, logScreen].compactMap { $0 as UIViewController? }

        // A screen of someone else's on top (a field editor over the form)
        // is left alone.
        let current = navigation.viewControllers
        guard let top = current.last, top === self || before.contains(top) || wanted.contains(top) else { return }
        let target = Array(current.prefix(through: index)) + wanted
        guard current != target else { return }
        if target.starts(with: current) {
            for next in target.dropFirst(current.count) { navigation.pushViewController(next, animated: next === target.last) }
        } else if current.starts(with: target), let last = target.last {
            navigation.popToViewController(last, animated: true)
        } else {
            navigation.setViewControllers(target, animated: false)
        }
    }

    private func screen<Screen: UIViewController>(_ existing: Screen?, wanted: Bool, make: () -> Screen) -> Screen? {
        wanted ? (existing ?? make()) : nil
    }

    private func makeEditor() -> ConfigItemViewController {
        let editor = ConfigItemViewController(store: collection, extras: { [store] in
            ConfigItemExtras(
                cronPreview: store.preview,
                links: [
                    .init(id: "prompt", title: String(localized: "Prompt"), symbol: "text.alignleft"),
                    .init(id: "history", title: String(localized: "History"), symbol: "clock.arrow.circlepath"),
                ],
                open: { store.send(.pageOpened($0 == "prompt" ? .prompt : .history)) }
            )
        })
        editor.onDidAppear = { [weak self] in self?.syncStack() }
        editor.loadViewIfNeeded()
        editor.present(item: $store.scope(state: \.formSaveDialog, action: \.formSaveDialog)) { store in
            UIAlertController(store: store)
        }
        return editor
    }

    // MARK: layout and cells

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.leadingSwipeActionsConfigurationProvider = { indexPath in
                guard let self, case .row(let name)? = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
                let run = UIContextualAction(style: .normal, title: String(localized: "Run Now")) { [store = self.store] _, _, done in
                    store.send(.runNowTapped(name))
                    done(true)
                }
                run.image = UIImage(systemName: "play.fill")
                run.backgroundColor = .systemBlue
                return UISwipeActionsConfiguration(actions: [run])
            }
            configuration.trailingSwipeActionsConfigurationProvider = { indexPath in
                guard let self, case .row(let name)? = self.dataSource.itemIdentifier(for: indexPath),
                      self.store.collection.core.allows(.delete) else { return nil }
                let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [store = self.store] _, _, done in
                    store.send(.collection(.deleteTapped(name)))
                    done(false)
                }
                return UISwipeActionsConfiguration(actions: [delete])
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.subtitleCell()
            cell.accessories = []
            switch item {
            case .row(let name):
                guard let self, let task = store.collection.core.items.first(where: { $0.name == name }) else { return }
                content.text = name
                content.secondaryText = task.values["schedule"]?.stringValue
                content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                content.secondaryTextProperties.color = .secondaryLabel
                cell.accessories = [.customView(configuration: .init(customView: toggle(for: task), placement: .trailing())), .disclosureIndicator()]
                cell.accessibilityIdentifier = "tasks.row.\(name)"
            case .loading:
                content.text = String(localized: "Loading…")
                content.textProperties.color = .secondaryLabel
            case .failed(let message):
                content.text = message
                content.textProperties.color = .systemRed
                cell.accessibilityIdentifier = "tasks.failed"
            case .retry:
                content.text = String(localized: "Try Again")
                content.textProperties.color = cell.tintColor
                cell.accessibilityIdentifier = "tasks.retry"
            case .empty:
                content.text = String(localized: "No tasks")
                content.textProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
    }

    private func toggle(for task: LeoConfigItem) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = store.toggles.isEnabled(task)
        toggle.accessibilityIdentifier = "tasks.enabled.\(task.name)"
        toggle.accessibilityLabel = String(localized: "\(task.name) enabled")
        toggle.addAction(UIAction { [store, name = task.name, weak toggle] _ in
            guard let toggle else { return }
            store.send(.toggleTapped(name, toggle.isOn))
        }, for: .valueChanged)
        return toggle
    }

    // MARK: selection and menus

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row?, .retry?: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .row(let name)?: store.send(.collection(.rowTapped(name)))
        case .retry?: store.send(.collection(.task))
        default: break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .row(let name)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let core = store.collection.core
        return UIContextMenuConfiguration(actionProvider: { [store] _ in
            var actions: [UIMenuElement] = [
                UIAction(title: String(localized: "Run Now"), image: UIImage(systemName: "play")) { _ in store.send(.runNowTapped(name)) },
            ]
            if core.actions.contains(.rename) {
                actions.append(UIAction(title: String(localized: "Rename"), image: UIImage(systemName: "pencil"),
                                        attributes: core.allows(.rename) ? [] : .disabled) { _ in store.send(.collection(.renameTapped(name))) })
            }
            if core.actions.contains(.duplicate) {
                actions.append(UIAction(title: String(localized: "Duplicate"), image: UIImage(systemName: "plus.square.on.square"),
                                        attributes: core.allows(.duplicate) ? [] : .disabled) { _ in store.send(.collection(.duplicateTapped(name))) })
            }
            if core.actions.contains(.delete) {
                actions.append(UIAction(title: String(localized: "Delete"), image: UIImage(systemName: "trash"),
                                        attributes: core.allows(.delete) ? .destructive : [.destructive, .disabled]) { _ in
                    store.send(.collection(.deleteTapped(name)))
                })
            }
            return UIMenu(children: actions)
        })
    }
}
