import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// The sheet that names a new item, a rename or a copy.
final class NameEntryViewController: UIViewController {
    private let store: StoreOf<NameEntry>
    private let field = UITextField()
    private let errorLabel = UILabel()
    private let scheduleField = UITextField()
    private let scheduleLabel = UILabel()
    private let submit: UIBarButtonItem

    init(store: StoreOf<NameEntry>) {
        self.store = store
        let title: String
        switch store.kind {
        case .add: title = String(localized: "Add")
        case .rename: title = String(localized: "Rename")
        case .duplicate: title = String(localized: "Duplicate")
        }
        submit = UIBarButtonItem(title: title, style: .done, target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        submit.primaryAction = UIAction(title: submit.title ?? "") { [store] _ in store.send(.submitTapped) }
        submit.accessibilityIdentifier = "config.name.submit"
        navigationItem.rightBarButtonItem = submit
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [store] _ in
            store.send(.cancelTapped)
        })

        field.accessibilityIdentifier = "config.name.field"
        field.text = store.text
        field.placeholder = String(localized: "Name")
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            store.send(.textChanged(field.text ?? ""))
        }, for: .editingChanged)
        field.addAction(UIAction { [store] _ in store.send(.submitTapped) }, for: .primaryActionTriggered)

        errorLabel.accessibilityIdentifier = "config.name.error"
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0

        scheduleField.accessibilityIdentifier = "config.name.schedule"
        scheduleField.placeholder = String(localized: "Schedule, like 0 9 * * *")
        scheduleField.borderStyle = .roundedRect
        scheduleField.autocapitalizationType = .none
        scheduleField.autocorrectionType = .no
        scheduleField.spellCheckingType = .no
        scheduleField.returnKeyType = .done
        scheduleField.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        scheduleField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            store.send(.scheduleChanged(scheduleField.text ?? ""))
        }, for: .editingChanged)
        scheduleField.addAction(UIAction { [store] _ in store.send(.submitTapped) }, for: .primaryActionTriggered)
        scheduleField.isHidden = !store.requiresSchedule

        scheduleLabel.accessibilityIdentifier = "config.name.schedulePreview"
        scheduleLabel.font = .preferredFont(forTextStyle: .footnote)
        scheduleLabel.adjustsFontForContentSizeCategory = true
        scheduleLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [field, errorLabel, scheduleField, scheduleLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        observe { [weak self] in
            guard let self else { return }
            errorLabel.text = store.error
            errorLabel.isHidden = store.error == nil
            renderSchedule()
        }
    }

    /// The reading of the schedule, or what is wrong with it.
    private func renderSchedule() {
        let message: (text: String, color: UIColor)? = switch (store.scheduleError, store.schedulePreview) {
        case (let error?, _): (error, .systemRed)
        case (nil, .invalid(let reason)?): (reason, .systemRed)
        case (nil, .valid(let text)?): (text, .secondaryLabel)
        case (nil, nil): nil
        }
        scheduleLabel.text = message?.text
        scheduleLabel.textColor = message?.color
        scheduleLabel.isHidden = message == nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        field.becomeFirstResponder()
    }
}
