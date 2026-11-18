import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import UIKitNavigation

/// Shows the one Delegation sheet the state calls for (a cell, a role's
/// description, the hidden agents, the Make Active preview) and dismisses it
/// when the state lets go. The sheets hold their edits until Cancel or Save,
/// so a swipe down can't drop one.
@MainActor
final class DelegationSheetPresenter {
    enum Kind: Equatable { case cell, useFor, hiddenAgents, preview }

    private let store: StoreOf<DelegationSettings>
    private let restart: StoreOf<MachineRestart>?
    private let host: () -> UIViewController?
    private var shown: (kind: Kind, controller: UIViewController)?

    init(store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>?, host: @escaping () -> UIViewController?) {
        self.store = store
        self.restart = restart
        self.host = host
    }

    static func kind(_ store: StoreOf<DelegationSettings>) -> Kind? {
        let core = store.core
        if core.cellEditor != nil { return .cell }
        if core.useForEditor != nil { return .useFor }
        if store.isEditingHiddenAgents { return .hiddenAgents }
        if core.preview != nil { return .preview }
        return nil
    }

    func sync() {
        let wanted = Self.kind(store)
        guard shown?.kind != wanted else { return }
        if let current = shown {
            shown = nil
            current.controller.dismiss(animated: true) { [weak self] in self?.sync() }
            return
        }
        guard let wanted, let host = host(), host.presentedViewController == nil else { return }
        let sheet = UINavigationController(rootViewController: make(wanted))
        sheet.modalPresentationStyle = .formSheet
        sheet.isModalInPresentation = true
        host.present(sheet, animated: true)
        shown = (wanted, sheet)
    }

    private func make(_ kind: Kind) -> UIViewController {
        switch kind {
        case .cell: DelegationCellEditorViewController(store: store, restart: restart)
        case .useFor: DelegationUseForViewController(store: store, restart: restart)
        case .hiddenAgents: DelegationHiddenAgentsViewController(store: store, restart: restart)
        case .preview: DelegationActivateViewController(store: store, restart: restart)
        }
    }
}

/// A Delegation sheet: the banners (a conflict answered here), then a form,
/// with Cancel and Save in the bar.
class DelegationSheetController: UIViewController {
    let store: StoreOf<DelegationSettings>
    private let restart: StoreOf<MachineRestart>?
    private let banners = ConfigBannerStack()
    let form = UIStackView()
    let saveButton: UIBarButtonItem

    init(store: StoreOf<DelegationSettings>, restart: StoreOf<MachineRestart>?, saveTitle: String) {
        self.store = store
        self.restart = restart
        saveButton = UIBarButtonItem(title: saveTitle, style: .done, target: nil, action: nil)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        saveButton.primaryAction = UIAction(title: saveButton.title ?? "") { [weak self] _ in self?.save() }
        saveButton.accessibilityIdentifier = "delegation.sheet.save"
        navigationItem.rightBarButtonItem = saveButton
        form.axis = .vertical
        form.spacing = 6
        form.isLayoutMarginsRelativeArrangement = true
        form.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 24, trailing: 20)
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        form.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(form)
        let stack = UIStackView(arrangedSubviews: [banners, scroll])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            form.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            form.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
        ])
        build()
        observe { [weak self] in
            guard let self else { return }
            banners.show(ConfigBanners.banners(store, restart: restart))
            update()
        }
    }

    /// Adds the form's views once.
    func build() {}
    /// Brings the form up to the state.
    func update() {}
    func cancel() {}
    func save() {}

    /// A field's title above it.
    static func caption(_ text: String) -> UILabel {
        let label = label(text, style: .footnote, color: .secondaryLabel)
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }

    static func label(_ text: String? = nil, style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    static func textField(placeholder: String, id: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.borderStyle = .roundedRect
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.accessibilityIdentifier = id
        return field
    }

    static func textView(id: String) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 10
        view.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        view.isScrollEnabled = false
        view.autocorrectionType = .no
        view.accessibilityIdentifier = id
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return view
    }

    /// Leaves room under a field before the next one.
    func gap(after view: UIView) { form.setCustomSpacing(16, after: view) }
}
