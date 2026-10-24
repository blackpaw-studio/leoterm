import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// One item's form: a section per layout group, with Save and Revert in the
/// bar. Back with unsaved edits asks first (see `ConfigCollection.backTapped`),
/// so the back button and the swipe are both held while the draft is dirty.
final class ConfigItemViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Hashable {
        case form(String)
        case web
    }

    private enum Item: Hashable {
        case field(String)
        case web
    }

    @UIBindable private var store: StoreOf<ConfigCollection>
    private let banners = ConfigBannerStack()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var rows: [String: LeoConfigFormRow] = [:]
    private var titles: [Section: String] = [:]
    private var webLink: URL?
    private var openEditor: (path: String, controller: any SchemaFieldEditorViewController)?
    private let saveButton = UIBarButtonItem(title: String(localized: "Save"), style: .done, target: nil, action: nil)
    private let revertButton = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: nil, action: nil)

    private lazy var handlers = SchemaFieldHandlers(
        edit: { [store] path, value in store.send(.field(path, value)) },
        revert: { [store] path in store.send(.revertTapped(path)) },
        push: { [weak self] editor in self?.push(editor) },
        promptSecret: { [weak self] title, done in self?.promptSecret(title, done: done) },
        open: { UIApplication.shared.open($0) }
    )

    init(store: StoreOf<ConfigCollection>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = store.core.selection
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backAction = UIAction { [store] _ in store.send(.backTapped) }
        saveButton.primaryAction = UIAction(title: String(localized: "Save")) { [store] _ in store.send(.saveTapped) }
        saveButton.accessibilityIdentifier = "config.save"
        revertButton.primaryAction = UIAction(image: UIImage(systemName: "arrow.uturn.backward")) { [store] _ in
            store.send(.revertAllTapped)
        }
        revertButton.accessibilityIdentifier = "config.revert"
        revertButton.accessibilityLabel = String(localized: "Revert changes")
        navigationItem.rightBarButtonItems = [saveButton, revertButton]

        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "config.form"
        collectionView.keyboardDismissMode = .interactive
        let stack = UIStackView(arrangedSubviews: [banners, collectionView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()

        present(item: $store.scope(state: \.leaveDialog, action: \.leaveDialog)) { [weak self] store in
            let dialog = UIAlertController(store: store)
            dialog.popoverPresentationController?.barButtonItem = self?.navigationItem.leftBarButtonItem ?? self?.saveButton
            return dialog
        }
        observe { [weak self] in self?.render() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !store.core.isDirty
    }

    /// Popped without going through `backAction` (a swipe while clean).
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { store.send(.backTapped) }
    }

    // MARK: rendering

    private func render() {
        let core = store.core
        title = core.selection
        saveButton.isEnabled = core.canSave
        revertButton.isEnabled = core.isDirty && !core.isBusy
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !core.isDirty
        banners.show(ConfigBanners.banners(store))

        let sections = core.sections
        rows = Dictionary(sections.flatMap(\.rows).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        webLink = core.webLink
        titles = Dictionary(sections.map { (Section.form($0.id), $0.title) }, uniquingKeysWith: { first, _ in first })

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for section in sections {
            snapshot.appendSections([.form(section.id)])
            snapshot.appendItems(section.rows.map { .field($0.path) }, toSection: .form(section.id))
        }
        if webLink != nil {
            snapshot.appendSections([.web])
            snapshot.appendItems([.web], toSection: .web)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)

        if let openEditor, let row = rows[openEditor.path] { openEditor.controller.update(row: row) }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let field = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .field(let path):
                guard let row = rows[path] else { return }
                cell.contentConfiguration = SchemaFieldContentConfiguration(row: row, cronPreview: nil, handlers: handlers)
                cell.accessibilityIdentifier = "config.field.\(path)"
            case .web:
                var content = UIListContentConfiguration.cell()
                content.text = String(localized: "Edit in the web UI")
                content.image = UIImage(systemName: "safari")
                content.textProperties.color = cell.tintColor
                cell.contentConfiguration = content
                cell.accessibilityIdentifier = "config.web"
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap { self?.titles[$0] }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: field, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .web
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let webLink { UIApplication.shared.open(webLink) }
    }

    // MARK: pushed editors and prompts

    private func push(_ editor: SchemaFieldEditor) {
        let controller = SchemaFieldEditors.make(editor, handlers: handlers)
        openEditor = (editor.row.path, controller)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func promptSecret(_ title: String, done: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: title, message: String(localized: "It is sent when you save."), preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = String(localized: "New value")
            field.accessibilityIdentifier = "config.secret.field"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in done(nil) })
        alert.addAction(UIAlertAction(title: String(localized: "Replace"), style: .default) { [weak alert] _ in
            done(alert?.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}
