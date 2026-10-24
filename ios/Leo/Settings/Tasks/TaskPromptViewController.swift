import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// A task's prompt file in a text view, with its own Save and conflict
/// handling. Leaving with unsaved text asks first: the back button and the
/// swipe are held while there is any, as on the form.
final class TaskPromptViewController: UIViewController, UITextViewDelegate {
    @UIBindable private var store: StoreOf<TaskSettings>
    private let banners = ConfigBannerStack()
    private let textView = UITextView()
    private let saveButton = UIBarButtonItem(title: String(localized: "Save"), style: .done, target: nil, action: nil)
    private let revertButton = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: nil, action: nil)

    init(store: StoreOf<TaskSettings>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Prompt")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backAction = UIAction { [store] _ in store.send(.promptBackTapped) }
        saveButton.primaryAction = UIAction(title: String(localized: "Save")) { [store] _ in store.send(.promptSaveTapped) }
        saveButton.accessibilityIdentifier = "task.prompt.save"
        revertButton.primaryAction = UIAction(image: UIImage(systemName: "arrow.uturn.backward")) { [store] _ in
            store.send(.promptRevertTapped)
        }
        revertButton.accessibilityIdentifier = "task.prompt.revert"
        revertButton.accessibilityLabel = String(localized: "Revert changes")
        navigationItem.rightBarButtonItems = [saveButton, revertButton]

        textView.delegate = self
        textView.accessibilityIdentifier = "task.prompt.text"
        textView.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let stack = UIStackView(arrangedSubviews: [banners, textView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        present(item: $store.scope(state: \.promptDialog, action: \.promptDialog)) { [weak self] store in
            let dialog = UIAlertController(store: store)
            // Anchored to the system back button's corner of the bar.
            if let bar = self?.navigationController?.navigationBar {
                dialog.popoverPresentationController?.sourceView = bar
                dialog.popoverPresentationController?.sourceRect = CGRect(x: bar.layoutMargins.left, y: bar.bounds.midY, width: 44, height: 0)
            }
            return dialog
        }
        present(item: $store.scope(state: \.promptLeave, action: \.promptLeave)) { [weak self] store in
            let dialog = UIAlertController(store: store)
            dialog.popoverPresentationController?.barButtonItem = self?.saveButton
            return dialog
        }
        observe { [weak self] in self?.render() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !store.prompt.isDirty
    }

    /// Popped without going through Back: clean, it is closed; dirty, the
    /// text stays and the list brings this screen back.
    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { store.send(.pagePopped(.prompt)) }
    }

    // MARK: rendering

    private func render() {
        let prompt = store.prompt
        let isDirty = prompt.isDirty
        saveButton.isEnabled = prompt.canWrite
        revertButton.isEnabled = isDirty && !prompt.isSaving
        navigationController?.interactivePopGestureRecognizer?.isEnabled = !isDirty
        title = prompt.document?.file.split(separator: "/").last.map(String.init) ?? String(localized: "Prompt")
        banners.show(banners(for: prompt))

        textView.isEditable = prompt.phase == .loaded && !prompt.isSaving
        // Only replace what is there when the store changed it (a reload, a
        // revert): rewriting the text under the caret would fight the typing.
        if textView.text != prompt.text { textView.text = prompt.text }
    }

    private func banners(for prompt: LeoTaskPromptState) -> [ConfigBanner] {
        var banners: [ConfigBanner] = []
        switch prompt.phase {
        case .loading:
            banners.append(ConfigBanner(id: "prompt.loading", style: .info, text: "Loading…"))
        case .unavailable(let message):
            banners.append(ConfigBanner(id: "prompt.unavailable", style: .warning, text: message))
        case .failed(let message):
            banners.append(ConfigBanner(id: "prompt.failed", style: .error, text: message))
        case .idle, .loaded:
            break
        }
        if prompt.conflict != nil {
            banners.append(ConfigBanner(
                id: "prompt.conflict", style: .warning, text: "This file changed on the machine since you opened it.",
                actions: [
                    .init(title: "Reload") { [store] in store.send(.promptReloadTapped) },
                    .init(title: "Overwrite") { [store] in store.send(.promptOverwriteTapped) },
                ]
            ))
        }
        if let error = prompt.error {
            banners.append(ConfigBanner(
                id: "prompt.error", style: .error, text: error, actions: [.init(title: "Dismiss") { [store] in store.send(.dismissPromptError) }]
            ))
        }
        return banners
    }

    func textViewDidChange(_ textView: UITextView) {
        store.send(.promptTextChanged(textView.text))
    }
}
