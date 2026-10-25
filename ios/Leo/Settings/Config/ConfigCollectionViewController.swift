import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// A collection resource's list (Templates, Environments). Opening a row
/// pushes its editor, which stays pushed for as long as the store has the
/// item selected.
final class ConfigCollectionViewController: UIViewController, UICollectionViewDelegate {
    private enum Item: Hashable {
        case row(String)
        case loading
        case failed(String)
        case retry
        case empty(String)
    }

    @UIBindable private var store: StoreOf<ConfigCollection>
    private let restart: StoreOf<MachineRestart>?
    private let banners = ConfigBannerStack()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var editor: ConfigItemViewController?
    private let addButton = UIBarButtonItem(systemItem: .add)

    init(store: StoreOf<ConfigCollection>, restart: StoreOf<MachineRestart>? = nil) {
        self.store = store
        self.restart = restart
        super.init(nibName: nil, bundle: nil)
        title = store.core.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backBarButtonItem = NoHistoryBackBarButtonItem()
        addButton.primaryAction = UIAction(image: UIImage(systemName: "plus")) { [store] _ in store.send(.addTapped) }
        addButton.accessibilityIdentifier = "config.add"
        addButton.accessibilityLabel = String(localized: "Add")
        navigationItem.rightBarButtonItem = addButton

        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "config.list"
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

        present(item: $store.scope(state: \.alert, action: \.alert)) { store in
            UIAlertController(store: store)
        }
        present(item: $store.scope(state: \.nameEntry, action: \.nameEntry)) { store in
            let sheet = UINavigationController(rootViewController: NameEntryViewController(store: store))
            sheet.modalPresentationStyle = .formSheet
            return sheet
        }
        observe { [weak self] in self?.render() }
        store.send(.task)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        syncEditor(isOpen: store.core.selection != nil)
    }

    // MARK: rendering

    private func render() {
        let core = store.core
        title = core.title
        addButton.isEnabled = core.allows(.add)
        addButton.isHidden = !core.actions.contains(.add)
        banners.show(ConfigBanners.banners(store, restart: restart))

        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch core.phase {
        case .loading where core.items.isEmpty: snapshot.appendItems([.loading])
        case .failed(let message): snapshot.appendItems([.failed(message), .retry])
        default:
            snapshot.appendItems(core.items.isEmpty ? [.empty(core.title)] : core.items.map { .row($0.name) })
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        syncEditor(isOpen: core.selection != nil)
    }

    /// The editor is pushed while an item is selected and popped when the
    /// store lets go of it (a Discard, a clean back, a delete).
    private func syncEditor(isOpen: Bool) {
        if isOpen, editor == nil {
            let pushed = ConfigItemViewController(store: store, restart: restart)
            editor = pushed
            navigationController?.pushViewController(pushed, animated: true)
        } else if isOpen, let pushed = editor, store.core.isDirty, navigationController?.topViewController === self,
                  navigationController?.viewControllers.contains(pushed) == false {
            // Something popped a dirty editor without asking (a pop to a
            // view controller further back): its edits are still here, so
            // it comes back, and leaving it then asks.
            navigationController?.pushViewController(pushed, animated: false)
        } else if !isOpen, let pushed = editor {
            editor = nil
            if navigationController?.viewControllers.contains(pushed) == true {
                navigationController?.popToViewController(self, animated: true)
            }
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.trailingSwipeActionsConfigurationProvider = { indexPath in
                guard let self, case .row(let name)? = self.dataSource.itemIdentifier(for: indexPath), self.store.core.allows(.delete) else {
                    return nil
                }
                let delete = UIContextualAction(style: .destructive, title: String(localized: "Delete")) { [store = self.store] _, _, done in
                    store.send(.deleteTapped(name))
                    done(false)
                }
                return UISwipeActionsConfiguration(actions: [delete])
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = UIListContentConfiguration.cell()
            cell.accessories = []
            switch item {
            case .row(let name):
                content.text = name
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "config.row.\(name)"
            case .loading:
                content.text = String(localized: "Loading…")
                content.textProperties.color = .secondaryLabel
            case .failed(let message):
                content.text = message
                content.textProperties.color = .systemRed
                cell.accessibilityIdentifier = "config.failed"
            case .retry:
                content.text = String(localized: "Try Again")
                content.textProperties.color = cell.tintColor
                cell.accessibilityIdentifier = "config.retry"
            case .empty(let title):
                content.text = String(localized: "No \(title.lowercased())")
                content.textProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
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
        case .row(let name)?: store.send(.rowTapped(name))
        case .retry?: store.send(.task)
        default: break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard case .row(let name)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let core = store.core
        return UIContextMenuConfiguration(actionProvider: { [store] _ in
            var actions: [UIMenuElement] = []
            if core.actions.contains(.rename) {
                actions.append(UIAction(title: String(localized: "Rename"), image: UIImage(systemName: "pencil"),
                                        attributes: core.allows(.rename) ? [] : .disabled) { _ in store.send(.renameTapped(name)) })
            }
            if core.actions.contains(.duplicate) {
                actions.append(UIAction(title: String(localized: "Duplicate"), image: UIImage(systemName: "plus.square.on.square"),
                                        attributes: core.allows(.duplicate) ? [] : .disabled) { _ in store.send(.duplicateTapped(name)) })
            }
            if core.actions.contains(.delete) {
                actions.append(UIAction(title: String(localized: "Delete"), image: UIImage(systemName: "trash"),
                                        attributes: core.allows(.delete) ? .destructive : [.destructive, .disabled]) { _ in
                    store.send(.deleteTapped(name))
                })
            }
            return UIMenu(children: actions)
        })
    }
}
