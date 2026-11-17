import LeoKit
import UIKit

/// One bar under the agent browser's address bar (B-305): the handoff
/// banner, a permission ask (D-890/D-891), a JavaScript dialog (B-412), or
/// why a page couldn't load. A symbol, a heading, the message, an optional
/// text field (a prompt's answer) and the buttons, trailing; the last
/// button is the prominent one. No button is the keyboard's default, so
/// Return never answers (D-891).
final class AgentBrowserBar: UIView {
    struct Button {
        let title: String
        var role: UIButton.Configuration = .gray()
        let id: String
        let action: () -> Void
    }

    private let symbol = UIImageView()
    private let heading = UILabel()
    private let message = UILabel()
    private let detail = UILabel()
    let textField = UITextField()
    private let buttons = UIStackView()

    init(id: String) {
        super.init(frame: .zero)
        accessibilityIdentifier = id
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        symbol.tintColor = .tintColor
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        heading.font = .preferredFont(forTextStyle: .subheadline)
        heading.textColor = .secondaryLabel
        heading.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.numberOfLines = 0
        message.accessibilityIdentifier = "\(id).message"
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        textField.borderStyle = .roundedRect
        textField.accessibilityIdentifier = "\(id).text"
        textField.returnKeyType = .default
        buttons.axis = .horizontal
        buttons.spacing = 8
        buttons.alignment = .center
        [heading, message, detail].forEach { $0.adjustsFontForContentSizeCategory = true }

        // The spacer takes the row's slack, so a bar with no heading keeps
        // its symbol at its natural size instead of stretching it.
        let titleRow = UIStackView(arrangedSubviews: [symbol, heading, UIView()])
        titleRow.spacing = 6
        titleRow.alignment = .firstBaseline
        let trailing = UIStackView(arrangedSubviews: [UIView(), buttons])
        let stack = UIStackView(arrangedSubviews: [titleRow, message, detail, textField, trailing])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        symbol name: String, tint: UIColor = .tintColor, heading: String?, message: String, detail: String? = nil,
        text: String? = nil, buttons: [Button]
    ) {
        symbol.image = UIImage(systemName: name)
        symbol.tintColor = tint
        self.heading.text = heading
        self.heading.isHidden = heading == nil
        self.message.text = message
        self.detail.text = detail
        self.detail.isHidden = detail == nil
        textField.isHidden = text == nil
        if let text, !textField.isFirstResponder { textField.text = text }
        self.buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, spec) in buttons.enumerated() {
            var configuration = index == buttons.count - 1 ? UIButton.Configuration.filled() : spec.role
            configuration.title = spec.title
            configuration.buttonSize = .small
            configuration.cornerStyle = .capsule
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in spec.action() })
            button.accessibilityIdentifier = spec.id
            self.buttons.addArrangedSubview(button)
        }
        self.buttons.isHidden = buttons.isEmpty
        accessibilityElements = [self.heading, self.message, self.detail, textField] + self.buttons.arrangedSubviews
    }
}

/// The control capsule over the page (as the Mac's pill, D-759): "Agent
/// driving", which a tap turns into the user's control, or "You have
/// control" with Give Back beside it. Hidden during a handoff, whose banner
/// has its own Done.
final class AgentBrowserControlPill: UIView {
    private let label = UIButton(configuration: .gray())
    private let giveBack = UIButton(configuration: .filled())
    var onTakeControl: (() -> Void)?
    var onGiveBack: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.configuration?.cornerStyle = .capsule
        label.configuration?.imagePadding = 6
        label.accessibilityIdentifier = "browser.pill"
        label.addAction(UIAction { [weak self] _ in self?.onTakeControl?() }, for: .primaryActionTriggered)
        giveBack.configuration?.cornerStyle = .capsule
        giveBack.configuration?.title = String(localized: "Give Back")
        giveBack.accessibilityIdentifier = "browser.giveBack"
        giveBack.accessibilityHint = String(localized: "Gives the browser back to the agent")
        giveBack.addAction(UIAction { [weak self] _ in self?.onGiveBack?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [label, giveBack])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ control: LeoBrowserControl) {
        isHidden = control.pendingHandoff != nil
        let isAgent = control.isAgentDriving
        label.configuration?.title = isAgent ? String(localized: "Agent driving") : String(localized: "You have control")
        label.configuration?.image = UIImage(systemName: isAgent ? "sparkles" : "person.fill")
        label.isUserInteractionEnabled = isAgent
        label.accessibilityHint = isAgent ? String(localized: "Takes control of the browser") : nil
        giveBack.isHidden = isAgent
    }
}
