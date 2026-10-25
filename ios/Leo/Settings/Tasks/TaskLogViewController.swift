import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// One run's log: the end of it, in a read-only monospaced text view.
final class TaskLogViewController: UIViewController {
    private let store: StoreOf<TaskSettings>
    private let banners = ConfigBannerStack()
    private let textView = UITextView()

    init(store: StoreOf<TaskSettings>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Log")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        textView.isEditable = false
        textView.accessibilityIdentifier = "task.log.text"
        textView.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let stack = UIStackView(arrangedSubviews: [banners, textView])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        observe { [weak self] in self?.render() }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { store.send(.pagePopped(.log)) }
    }

    private func render() {
        var notes: [ConfigBanner] = []
        let text: String
        switch store.log {
        case .idle, .loading:
            text = ""
            notes.append(ConfigBanner(id: "log.loading", style: .info, text: "Loading…"))
        case .failed(let message):
            text = ""
            notes.append(ConfigBanner(id: "log.failed", style: .error, text: message))
        case .loaded(let log):
            text = log.text
            if log.truncated { notes.append(ConfigBanner(id: "log.truncated", style: .info, text: "Showing the end of a long log.")) }
            if log.text.isEmpty { notes.append(ConfigBanner(id: "log.empty", style: .info, text: "This run wrote nothing.")) }
        }
        banners.show(notes)
        if textView.text != text { textView.text = text }
    }
}
