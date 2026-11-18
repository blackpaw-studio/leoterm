import LeoKit
import UIKit

/// What a pane adds to its items' forms: the live reading of a schedule, and
/// rows that open the item's other screens (a task's prompt and history).
struct ConfigItemExtras {
    struct Link: Hashable {
        let id: String
        let title: String
        let symbol: String
    }

    var cronPreview: LeoCronPreviewResult?
    var links: [Link] = []
    var open: (String) -> Void = { _ in }
}

/// A schema form's body, for any store that holds a draft (a collection's
/// item, a singleton): the banners over a list with a section per layout
/// group, the extras' links, and "Edit in the web UI". Field edits go out
/// through `edit` and `revert`; editors that need a screen of their own are
/// pushed on the owning controller's navigation stack.
@MainActor
final class SchemaFormHost: NSObject, UICollectionViewDelegate {
    /// One render's worth of what the form shows.
    struct Content {
        var sections: [LeoConfigFormSection]
        var webLink: URL?
        var banners: [ConfigBanner]
        var extras = ConfigItemExtras()
    }

    private enum Section: Hashable {
        case form(String)
        case links
        case web
    }

    private enum Item: Hashable {
        case field(String)
        case link(ConfigItemExtras.Link)
        case web
    }

    private let banners = ConfigBannerStack()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private weak var controller: UIViewController?
    private var rows: [String: LeoConfigFormRow] = [:]
    private var titles: [Section: String] = [:]
    private var webLink: URL?
    private var extras = ConfigItemExtras()
    private var openEditor: (path: String, controller: any SchemaFieldEditorViewController)?
    private var handlers = SchemaFieldHandlers()

    init(edit: @escaping (String, LeoConfigValue) -> Void, revert: @escaping (String) -> Void) {
        super.init()
        handlers = SchemaFieldHandlers(
            edit: edit, revert: revert,
            push: { [weak self] editor in self?.push(editor) },
            promptSecret: { [weak self] title, done in self?.promptSecret(title, done: done) },
            open: { UIApplication.shared.open($0) }
        )
    }

    /// Lays the banners and the list out in `controller`'s view, above the keyboard.
    func install(in controller: UIViewController) {
        self.controller = controller
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "config.form"
        collectionView.keyboardDismissMode = .interactive
        let stack = UIStackView(arrangedSubviews: [banners, collectionView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = controller.view!
        view.addSubview(stack)
        // To the view's edge while the keyboard is down, so the form scrolls
        // under the home indicator instead of stopping above it.
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()
    }

    func render(_ content: Content) {
        banners.show(content.banners)
        extras = content.extras
        rows = Dictionary(content.sections.flatMap(\.rows).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        webLink = content.webLink
        titles = Dictionary(content.sections.map { (Section.form($0.id), $0.title) }, uniquingKeysWith: { first, _ in first })

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for section in content.sections {
            snapshot.appendSections([.form(section.id)])
            snapshot.appendItems(section.rows.map { .field($0.path) }, toSection: .form(section.id))
        }
        if !extras.links.isEmpty {
            snapshot.appendSections([.links])
            snapshot.appendItems(extras.links.map(Item.link), toSection: .links)
        }
        if webLink != nil {
            snapshot.appendSections([.web])
            snapshot.appendItems([.web], toSection: .web)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)

        if let openEditor, let row = rows[openEditor.path] { openEditor.controller.update(row: row) }
    }

    private static func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.headerMode = .supplementary
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let field = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            switch item {
            case .field(let path):
                guard let row = rows[path] else { return }
                cell.contentConfiguration = SchemaFieldContentConfiguration(
                    row: row, cronPreview: row.control == .cron ? extras.cronPreview : nil, handlers: handlers
                )
                cell.accessibilityIdentifier = "config.field.\(path)"
            case .link(let link):
                var content = UIListContentConfiguration.cell()
                content.text = link.title
                content.image = UIImage(systemName: link.symbol)
                cell.contentConfiguration = content
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "config.link.\(link.id)"
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
        switch dataSource.itemIdentifier(for: indexPath) {
        case .web?, .link?: true
        case .field(let path)?: rows[path].map { SchemaFieldControls.isActivatable($0.control) } ?? false
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .link(let link)?: extras.open(link.id)
        case .web?: if let webLink { UIApplication.shared.open(webLink) }
        case .field?: collectionView.cellForItem(at: indexPath)?.firstSubview(ofType: SchemaFieldContentView.self)?.activate()
        default: break
        }
    }

    // MARK: pushed editors and prompts

    private func push(_ editor: SchemaFieldEditor) {
        let pushed = SchemaFieldEditors.make(editor, handlers: handlers)
        openEditor = (editor.row.path, pushed)
        controller?.navigationController?.pushViewController(pushed, animated: true)
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
        controller?.present(alert, animated: true)
    }
}

private extension UIView {
    func firstSubview<View: UIView>(ofType type: View.Type) -> View? {
        subviews.lazy.compactMap { ($0 as? View) ?? $0.firstSubview(ofType: type) }.first
    }
}
