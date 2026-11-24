import LeoFeatures
import LeoKit
import UIKit

/// What a card's buttons do; the Chats screen wires each to the store.
struct ChatInboxCardActions {
    var answer: (LeoChatAnswer) -> Void = { _ in }
    var openChat: () -> Void = {}
    var goToAgent: () -> Void = {}
}

/// One needs-you or finished item: who, when, what, and (for an ask) how to answer.
struct ChatInboxCardConfiguration: UIContentConfiguration {
    let item: LeoInboxItem
    /// The agent's chat row, for its avatar; nil when it is not in the fleet.
    let row: ChatRow?
    /// The daemon's reason the last inline answer failed.
    let error: String?
    var now = Date()
    var actions = ChatInboxCardActions()

    func makeContentView() -> any UIView & UIContentView { ChatInboxCardContentView(configuration: self) }

    func updated(for state: any UIConfigurationState) -> ChatInboxCardConfiguration { self }

    /// What VoiceOver reads for the card.
    var accessibilityText: String {
        [item.agent, item.machine, item.kind.leadIn, item.kind.body, item.isUnread && !item.isBlocked ? String(localized: "Unread") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

extension ChatInboxCardConfiguration: Equatable {
    /// The actions are closures; a card is the same when what it shows is.
    static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.item, lhs.row, lhs.error, lhs.now) == (rhs.item, rhs.row, rhs.error, rhs.now)
    }
}

extension LeoInboxKind {
    /// The colored lead-in before the body: "Asks:", "Permission:"…
    var leadIn: String? {
        switch self {
        case .chatAsk(let message): message.kind == .permission ? String(localized: "Permission:") : String(localized: "Asks:")
        case .permission: String(localized: "Permission:")
        case .question: String(localized: "Asks:")
        case .finished: nil
        }
    }

    var body: String? {
        switch self {
        case .chatAsk(let message): message.text
        case .permission(let tool, _): tool
        case .question(let text): text ?? String(localized: "Waiting for your input")
        case .finished(let result): result
        }
    }

    /// The command or detail shown in a monospaced box.
    var command: String? {
        switch self {
        case .permission(_, let detail): detail
        default: nil
        }
    }
}

private final class ChatInboxCardContentView: UIView, UIContentView, UITextFieldDelegate {
    private let avatar = ChatAvatarView()
    private let name = UILabel()
    private let time = UILabel()
    private let machine = UILabel()
    private let text = UILabel()
    private let context = UILabel()
    private let commandBox = UIView()
    private let command = UILabel()
    private let error = UILabel()
    private let unreadDot = UIView()
    private let controls = UIStackView()
    private var isReplying = false
    private var shownID: LeoAgentID?
    private let replyField = UITextField()

    var configuration: any UIContentConfiguration {
        didSet { apply() }
    }

    private var card: ChatInboxCardConfiguration? { configuration as? ChatInboxCardConfiguration }

    init(configuration: ChatInboxCardConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        name.font = .preferredFont(forTextStyle: .headline)
        name.adjustsFontForContentSizeCategory = true
        time.font = .preferredFont(forTextStyle: .subheadline)
        time.textColor = .secondaryLabel
        time.adjustsFontForContentSizeCategory = true
        time.setContentHuggingPriority(.required, for: .horizontal)
        machine.font = .preferredFont(forTextStyle: .footnote)
        machine.textColor = .secondaryLabel
        machine.adjustsFontForContentSizeCategory = true
        for label in [text, context, error] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        text.font = .preferredFont(forTextStyle: .subheadline)
        context.font = .preferredFont(forTextStyle: .footnote)
        context.textColor = .secondaryLabel
        error.font = .preferredFont(forTextStyle: .footnote)
        error.textColor = .systemRed
        command.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        command.numberOfLines = 0
        command.translatesAutoresizingMaskIntoConstraints = false
        commandBox.backgroundColor = .tertiarySystemFill
        commandBox.layer.cornerRadius = 8
        commandBox.addSubview(command)
        NSLayoutConstraint.activate([
            command.topAnchor.constraint(equalTo: commandBox.topAnchor, constant: 8),
            command.bottomAnchor.constraint(equalTo: commandBox.bottomAnchor, constant: -8),
            command.leadingAnchor.constraint(equalTo: commandBox.leadingAnchor, constant: 10),
            command.trailingAnchor.constraint(equalTo: commandBox.trailingAnchor, constant: -10),
        ])
        unreadDot.backgroundColor = .systemBlue
        unreadDot.layer.cornerRadius = 5
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([unreadDot.widthAnchor.constraint(equalToConstant: 10), unreadDot.heightAnchor.constraint(equalToConstant: 10)])
        controls.axis = .vertical
        controls.spacing = 8
        replyField.borderStyle = .none
        replyField.backgroundColor = .tertiarySystemFill
        replyField.layer.cornerRadius = 18
        replyField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        replyField.leftViewMode = .always
        replyField.returnKeyType = .send
        replyField.delegate = self
        replyField.font = .preferredFont(forTextStyle: .subheadline)
        replyField.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        let top = UIStackView(arrangedSubviews: [name, unreadDot, UIView(), time])
        top.spacing = 6
        top.alignment = .center
        let body = UIStackView(arrangedSubviews: [top, machine, context, text, commandBox, controls, error])
        body.axis = .vertical
        body.spacing = 4
        body.setCustomSpacing(8, after: machine)
        body.setCustomSpacing(8, after: text)
        body.setCustomSpacing(8, after: commandBox)
        let row = UIStackView(arrangedSubviews: [avatar, body])
        row.spacing = 12
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func apply() {
        guard let card else { return }
        let item = card.item
        if shownID != item.id {
            shownID = item.id
            isReplying = false
            replyField.text = nil
        }
        if let row = card.row { avatar.configure(row) }
        avatar.isHidden = card.row == nil
        name.text = item.agent
        name.font = .preferredFont(forTextStyle: .headline).withWeight(item.isUnread ? .bold : .semibold)
        time.text = item.at.map { ChatPresentation.time($0, now: card.now) }
        machine.text = [item.projectLabel, item.machine].compactMap { $0 }.joined(separator: " · ")
        context.text = item.context
        context.isHidden = item.context == nil
        text.attributedText = Self.bodyText(item)
        command.text = item.kind.command
        commandBox.isHidden = command.text == nil
        unreadDot.isHidden = item.isBlocked || !item.isUnread
        error.text = card.error
        error.isHidden = card.error == nil
        rebuildControls(card)
    }

    private static func bodyText(_ item: LeoInboxItem) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lead: (String, UIColor)? = if let leadIn = item.kind.leadIn {
            (leadIn, .systemOrange)
        } else if item.isError {
            (String(localized: "Error:"), .systemRed)
        } else {
            nil
        }
        if let lead {
            result.append(NSAttributedString(string: "\(lead.0) ", attributes: [
                .foregroundColor: lead.1, .font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold),
            ]))
        }
        let body = item.kind.body ?? (item.isBlocked ? "" : String(localized: "Finished"))
        let color: UIColor = item.isBlocked || item.isError ? .label : .secondaryLabel
        result.append(NSAttributedString(string: body, attributes: [.foregroundColor: color]))
        return result
    }

    // MARK: Controls

    private func rebuildControls(_ card: ChatInboxCardConfiguration) {
        controls.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard card.item.isBlocked else { return }
        switch card.item.kind {
        case .chatAsk(let message):
            if message.kind == .permission {
                controls.addArrangedSubview(goToAgentButton(card))
            } else if let input = message.input {
                askControls(input, card: card)
            } else {
                controls.addArrangedSubview(linksRow([(String(localized: "Open chat"), card.actions.openChat)]))
            }
        case .permission, .question:
            controls.addArrangedSubview(goToAgentButton(card))
        case .finished:
            break
        }
    }

    private func askControls(_ input: LeoChatInput, card: ChatInboxCardConfiguration) {
        let openChat = (String(localized: "Open chat"), card.actions.openChat)
        if input.isSingleChoice {
            for option in input.options {
                var configuration = UIButton.Configuration.tinted()
                configuration.title = option.label
                configuration.titleLineBreakMode = .byWordWrapping
                configuration.cornerStyle = .large
                let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
                    card.actions.answer(LeoChatAnswer(values: [option.value]))
                })
                button.accessibilityIdentifier = "inbox.option.\(option.value)"
                controls.addArrangedSubview(button)
            }
            if input.allowsText {
                if isReplying {
                    controls.addArrangedSubview(replyRow(card))
                } else {
                    controls.addArrangedSubview(linksRow([
                        (String(localized: "Reply instead"), { [weak self] in
                            self?.isReplying = true
                            self?.apply()
                            self?.replyField.becomeFirstResponder()
                        }),
                        openChat,
                    ]))
                    return
                }
            }
            controls.addArrangedSubview(linksRow([openChat]))
        } else if input.kind == .text {
            controls.addArrangedSubview(replyRow(card))
            controls.addArrangedSubview(linksRow([openChat]))
        } else {
            // Checkboxes and multi-question cards are answered in the thread.
            controls.addArrangedSubview(linksRow([openChat]))
        }
    }

    private func replyRow(_ card: ChatInboxCardConfiguration) -> UIView {
        replyField.placeholder = String(localized: "Reply to \(card.item.agent)…")
        var send = UIButton.Configuration.filled()
        send.image = UIImage(systemName: "arrow.up")
        send.cornerStyle = .capsule
        let button = UIButton(configuration: send, primaryAction: UIAction { [weak self] _ in self?.submitReply() })
        button.accessibilityLabel = String(localized: "Send")
        button.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [replyField, button])
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func submitReply() {
        let reply = replyField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reply.isEmpty else { return }
        replyField.text = nil
        card?.actions.answer(LeoChatAnswer(text: reply))
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitReply()
        return false
    }

    private func goToAgentButton(_ card: ChatInboxCardConfiguration) -> UIView {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Go to agent")
        configuration.image = UIImage(systemName: "terminal")
        configuration.imagePadding = 6
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in card.actions.goToAgent() })
        button.accessibilityIdentifier = "inbox.goToAgent"
        return button
    }

    private func linksRow(_ links: [(String, () -> Void)]) -> UIView {
        let row = UIStackView()
        row.distribution = .equalSpacing
        for (title, action) in links {
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
            row.addArrangedSubview(UIButton(configuration: configuration, primaryAction: UIAction { _ in action() }))
        }
        if links.count == 1 { row.addArrangedSubview(UIView()) }
        return row
    }
}
