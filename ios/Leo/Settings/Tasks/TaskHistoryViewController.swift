import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// A task's recent runs, newest first. A run opens its log.
final class TaskHistoryViewController: UIViewController, UICollectionViewDelegate {
    private enum Item: Hashable {
        case run(String)
        case loading
        case failed(String)
        case empty
    }

    private let store: StoreOf<TaskSettings>
    private lazy var collectionView = UICollectionView(
        frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: UICollectionLayoutListConfiguration(appearance: .insetGrouped))
    )
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init(store: StoreOf<TaskSettings>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "History")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "task.history"
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            var content = UIListContentConfiguration.subtitleCell()
            cell.accessories = []
            switch item {
            case .run(let id):
                guard let run = self?.run(id) else { return }
                content.text = run.startedAt?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "Unknown start")
                content.secondaryText = Self.detail(of: run)
                content.secondaryTextProperties.color = .secondaryLabel
                content.image = UIImage(systemName: Self.symbol(of: run))
                content.imageProperties.tintColor = run.succeeded == false ? .systemRed : run.succeeded == true ? .systemGreen : .secondaryLabel
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "task.history.run.\(run.id)"
            case .loading:
                content.text = String(localized: "Loading…")
                content.textProperties.color = .secondaryLabel
            case .failed(let message):
                content.text = message
                content.textProperties.color = .systemRed
            case .empty:
                content.text = String(localized: "No runs yet")
                content.textProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        observe { [weak self] in self?.render() }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { store.send(.pagePopped(.history)) }
    }

    private func render() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        switch store.history {
        case .idle, .loading: snapshot.appendItems([.loading])
        case .failed(let message): snapshot.appendItems([.failed(message)])
        case .loaded(let runs): snapshot.appendItems(runs.isEmpty ? [.empty] : runs.map { Item.run($0.id) })
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func run(_ id: String) -> LeoTaskRun? {
        guard case .loaded(let runs) = store.history else { return nil }
        return runs.first { $0.id == id }
    }

    private static func symbol(of run: LeoTaskRun) -> String {
        switch run.succeeded {
        case true?: "checkmark.circle.fill"
        case false?: "xmark.circle.fill"
        case nil: "questionmark.circle"
        }
    }

    private static func detail(of run: LeoTaskRun) -> String {
        var parts: [String] = []
        if let code = run.exitCode { parts.append(code == 0 ? String(localized: "Succeeded") : String(localized: "Exit \(code)")) }
        if let milliseconds = run.durationMs { parts.append(Duration.milliseconds(milliseconds).formatted(.units(allowed: [.hours, .minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2))) }
        return parts.joined(separator: " · ")
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .run? = dataSource.itemIdentifier(for: indexPath) { true } else { false }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if case .run(let id)? = dataSource.itemIdentifier(for: indexPath), let run = run(id) { store.send(.runTapped(run)) }
    }
}
