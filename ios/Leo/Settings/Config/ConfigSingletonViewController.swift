import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// A singleton's form (Defaults, Web UI, Remote client): a section per layout
/// group, with Save and Revert in the bar. Back with unsaved edits asks first
/// (see `ConfigSingleton.backTapped`), so the back button and the swipe are
/// both held while the draft is dirty. The form's body is a `SchemaFormHost`.
final class ConfigSingletonViewController: UIViewController {
    @UIBindable private var store: StoreOf<ConfigSingleton>
    private let restart: StoreOf<MachineRestart>?
    let saveButton = UIBarButtonItem(title: String(localized: "Save"), style: .done, target: nil, action: nil)
    private let revertButton = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: nil, action: nil)
    private let loading = UIActivityIndicatorView(style: .medium)
    private let failure = UILabel()
    private lazy var form = SchemaFormHost(
        edit: { [store] path, value in store.send(.field(path, value)) },
        revert: { [store] path in store.send(.revertTapped(path)) }
    )

    init(store: StoreOf<ConfigSingleton>, restart: StoreOf<MachineRestart>? = nil) {
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
        navigationItem.backAction = UIAction { [store] _ in store.send(.backTapped) }
        navigationItem.backBarButtonItem = NoHistoryBackBarButtonItem()
        saveButton.primaryAction = UIAction(title: String(localized: "Save")) { [store] _ in store.send(.saveTapped) }
        saveButton.accessibilityIdentifier = "config.save"
        revertButton.primaryAction = UIAction(image: UIImage(systemName: "arrow.uturn.backward")) { [store] _ in
            store.send(.revertAllTapped)
        }
        revertButton.accessibilityIdentifier = "config.revert"
        revertButton.accessibilityLabel = String(localized: "Revert changes")
        navigationItem.rightBarButtonItems = [saveButton, revertButton]
        form.install(in: self)
        installStatusViews()

        present(item: $store.scope(state: \.leaveDialog, action: \.leaveDialog)) { [weak self] store in
            guard let self else { return UIAlertController(store: store) }
            return UIAlertController(store: store).anchoredToBack(of: self)
        }
        observe { [weak self] in self?.render() }
        store.send(.task)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !store.core.isDirty
    }

    private func installStatusViews() {
        failure.numberOfLines = 0
        failure.textAlignment = .center
        failure.textColor = .secondaryLabel
        failure.font = .preferredFont(forTextStyle: .body)
        failure.adjustsFontForContentSizeCategory = true
        failure.accessibilityIdentifier = "config.failure"
        for status in [loading, failure] as [UIView] {
            status.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(status)
        }
        NSLayoutConstraint.activate([
            loading.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failure.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failure.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            failure.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    private func render() {
        let core = store.core
        title = core.title
        saveButton.isEnabled = core.canSave
        revertButton.isEnabled = core.isDirty && !core.isBusy
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !core.isDirty
        switch core.phase {
        case .loading where core.draft == nil:
            loading.startAnimating()
            failure.isHidden = true
        case .failed(let message) where core.draft == nil:
            loading.stopAnimating()
            failure.text = message
            failure.isHidden = false
        default:
            loading.stopAnimating()
            failure.isHidden = true
        }
        form.render(SchemaFormHost.Content(
            sections: core.sections, webLink: core.webLink, banners: ConfigBanners.banners(store, restart: restart)
        ))
    }
}
