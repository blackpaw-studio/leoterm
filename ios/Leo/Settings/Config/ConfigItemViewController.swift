import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// One item's form: a section per layout group, with Save and Revert in the
/// bar. Back with unsaved edits asks first (see `ConfigCollection.backTapped`),
/// so the back button and the swipe are both held while the draft is dirty.
/// The form's body is a `SchemaFormHost`.
final class ConfigItemViewController: UIViewController {
    @UIBindable private var store: StoreOf<ConfigCollection>
    private let extras: (() -> ConfigItemExtras)?
    private let restart: StoreOf<MachineRestart>?
    /// Told when the form comes back into view: a pane that pushed screens
    /// over it checks they are still where its state wants them.
    var onDidAppear: (() -> Void)?
    let saveButton = UIBarButtonItem(title: String(localized: "Save"), style: .done, target: nil, action: nil)
    private let revertButton = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: nil, action: nil)
    private lazy var form = SchemaFormHost(
        edit: { [store] path, value in store.send(.field(path, value)) },
        revert: { [store] path in store.send(.revertTapped(path)) }
    )

    init(store: StoreOf<ConfigCollection>, restart: StoreOf<MachineRestart>? = nil, extras: (() -> ConfigItemExtras)? = nil) {
        self.store = store
        self.restart = restart
        self.extras = extras
        super.init(nibName: nil, bundle: nil)
        title = store.core.selection
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        // The system back button asks through `backAction`; the one this
        // screen's own back button would show for what's pushed on top has no
        // history menu, which would jump past the question.
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

        present(item: $store.scope(state: \.leaveDialog, action: \.leaveDialog)) { [weak self] store in
            guard let self else { return UIAlertController(store: store) }
            return UIAlertController(store: store).anchoredToBack(of: self)
        }
        observe { [weak self] in self?.render() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !isDirty
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onDidAppear?()
    }

    private var isDirty: Bool { store.core.isDirty || store.extraUnsaved }

    /// Popped without going through the back button (a swipe while clean, or
    /// something else). A dirty draft stays, and the list brings this back.
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { store.send(.editorPopped) }
    }

    private func render() {
        let core = store.core
        title = core.selection
        saveButton.isEnabled = core.canSave
        revertButton.isEnabled = core.isDirty && !core.isBusy
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !isDirty
        form.render(SchemaFormHost.Content(
            sections: core.sections, webLink: core.webLink, banners: ConfigBanners.banners(store, restart: restart),
            extras: extras?() ?? ConfigItemExtras()
        ))
    }
}
