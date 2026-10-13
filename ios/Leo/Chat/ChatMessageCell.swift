import LeoFeatures
import LeoKit
import UIKit

/// One chat message: a bubble (the agent's on the leading side, yours on
/// the trailing side), a full-width card for task output, or a centered
/// line for system notes. Carries attachments, an open prompt's answer
/// controls, "Show more" and, on task cards, a reply button. An `ask` that
/// follows up the agent's post sits tight under it.
final class ChatMessageCell: UICollectionViewCell {
    enum Event {
        /// An option tapped in an open prompt.
        case choice(String)
        /// The prompt's free text changed.
        case text(String)
        case submit
        case expand
        case openAttachment(LeoChatAttachment)
        case playVoice(LeoChatAttachment)
        case reply
    }

    struct Model {
        let message: LeoChatMessage
        let isExpanded: Bool
        let isAnswering: Bool
        let draft: LeoChatAskDraft
        let continuesPost: Bool
        let files: [String: ChatThread.AttachmentFile]
        let playingAttachmentID: String?
    }

    private static let bubbleSpacing: CGFloat = 3

    private let bubble = UIView()
    private let stack = UIStackView()
    private let header = UILabel()
    private let body = UILabel()
    private let footer = UILabel()
    /// Kept across reconfigures (see `ChatAskControls`).
    private let askControls = ChatAskControls()
    private var top: NSLayoutConstraint!
    private var leading: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private var centered: NSLayoutConstraint!
    private var onEvent: (Event) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(stack)
        for label in [header, body, footer] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        header.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        header.textColor = .secondaryLabel
        body.font = .preferredFont(forTextStyle: .body)
        footer.font = .preferredFont(forTextStyle: .caption2)
        footer.textColor = .secondaryLabel
        leading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        trailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        centered = bubble.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        top = bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.bubbleSpacing)
        NSLayoutConstraint.activate([
            top,
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 12),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -9),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -13),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ model: Model, onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        askControls.onEvent = onEvent
        let message = model.message
        layout(for: message)
        top.constant = model.continuesPost ? 0 : Self.bubbleSpacing
        accessibilityIdentifier = "chat.message.\(message.id)"
        let views = contentViews(model)
        // Everything is rebuilt but the ask controls, which stay in place
        // so a focused text field keeps the keyboard.
        stack.arrangedSubviews.filter { $0 !== askControls }.forEach { $0.removeFromSuperview() }
        guard let split = views.firstIndex(where: { $0 === askControls }) else {
            askControls.removeFromSuperview()
            views.forEach(stack.addArrangedSubview)
            return
        }
        if askControls.superview !== stack { stack.addArrangedSubview(askControls) }
        for (index, view) in views[..<split].enumerated() { stack.insertArrangedSubview(view, at: index) }
        views[(split + 1)...].forEach(stack.addArrangedSubview)
    }

    /// The bubble's contents, top to bottom.
    private func contentViews(_ model: Model) -> [UIView] {
        let message = model.message
        var views: [UIView] = []
        if message.kind == .task {
            header.text = "\(message.task ?? String(localized: "Task")) · \(ChatPresentation.time(message.ts))"
            views.append(header)
        } else if message.kind == .permission {
            header.text = String(localized: "Permission request")
            views.append(header)
        }

        let text = message.displayText
        if !text.isEmpty {
            body.text = text
            body.textColor = message.kind == .system ? .secondaryLabel : .label
            body.font = .preferredFont(forTextStyle: message.kind == .system ? .footnote : .body)
            body.textAlignment = message.kind == .system ? .center : .natural
            let collapsesToOneLine = message.kind == .task && !model.isExpanded
            let isLong = ChatPresentation.isLong(text)
            body.numberOfLines = collapsesToOneLine ? 1 : (isLong && !model.isExpanded ? ChatPresentation.collapsedLineLimit : 0)
            views.append(body)
            if message.kind == .task || isLong {
                let title = model.isExpanded ? String(localized: "Show less") : (message.kind == .task ? String(localized: "Show") : String(localized: "Show more"))
                views.append(linkButton(title) { $0(.expand) })
            }
        }

        views += message.attachments.map { view(for: $0, model: model) }
        views += promptViews(model)
        if message.kind == .task { views.append(linkButton(String(localized: "Reply")) { $0(.reply) }) }

        let state = ChatPresentation.stateLine(message)
        if message.kind != .system, message.kind != .task {
            footer.text = [ChatPresentation.time(message.ts), state].compactMap { $0 }.joined(separator: " · ")
            footer.textColor = message.isFailed ? .systemRed : .secondaryLabel
            footer.textAlignment = message.direction == .inbound ? .right : .left
            views.append(footer)
        }
        return views
    }

    /// The ask's text field while it is being edited, in `view`'s coordinates.
    func focusedTextFrame(in view: UIView) -> CGRect? {
        askControls.superview == nil ? nil : askControls.focusedTextFrame(in: view)
    }

    private func layout(for message: LeoChatMessage) {
        NSLayoutConstraint.deactivate([leading, trailing, centered])
        switch (message.kind, message.direction) {
        case (.system, _):
            bubble.backgroundColor = .clear
            centered.isActive = true
        case (.task, _):
            bubble.backgroundColor = .secondarySystemGroupedBackground
            NSLayoutConstraint.activate([leading, trailing])
        case (_, .inbound):
            bubble.backgroundColor = .tintColor.withAlphaComponent(0.18)
            trailing.isActive = true
        case (_, .outbound):
            bubble.backgroundColor = .secondarySystemBackground
            leading.isActive = true
        }
    }

    /// An open prompt's controls; a closed one's outcome.
    private func promptViews(_ model: Model) -> [UIView] {
        let message = model.message
        guard let input = message.answerInput else { return [] }
        if message.isOpen {
            askControls.configure(ChatAskControls.Model(message: message, input: input, draft: model.draft, isAnswering: model.isAnswering))
            return [askControls]
        }
        let status = UILabel()
        status.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        status.textColor = .secondaryLabel
        status.numberOfLines = 0
        status.text = switch message.state {
        case "answered" where message.isAnsweredInTerminal: String(localized: "Answered in terminal")
        case "answered": String(localized: "Answered: \(message.answerSummary ?? "")")
        case "expired": String(localized: "Expired")
        default: nil
        }
        return status.text == nil ? [] : [status]
    }

    private func view(for attachment: LeoChatAttachment, model: Model) -> UIView {
        guard attachment.available else {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            label.text = String(localized: "\(attachment.filename) (no longer stored)")
            return label
        }
        let file = model.files[attachment.id]
        if attachment.isImage {
            if case .loaded(let url) = file, let image = UIImage(contentsOfFile: url.path())?.preparingThumbnail(of: CGSize(width: 600, height: 600)) {
                let imageView = UIImageView(image: image)
                imageView.contentMode = .scaleAspectFit
                imageView.layer.cornerRadius = 12
                imageView.clipsToBounds = true
                imageView.isUserInteractionEnabled = true
                imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
                let ratio = image.size.height / max(image.size.width, 1)
                imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: ratio).withPriority(.defaultHigh).isActive = true
                imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(imageTapped(_:))))
                imageView.accessibilityLabel = attachment.filename
                imageView.isAccessibilityElement = true
                tappedAttachments[ObjectIdentifier(imageView)] = attachment
                return imageView
            }
        }
        if attachment.isAudio {
            let isPlaying = model.playingAttachmentID == attachment.id
            var configuration = UIButton.Configuration.tinted()
            configuration.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
            configuration.title = isPlaying ? String(localized: "Playing") : String(localized: "Voice note")
            configuration.imagePadding = 8
            configuration.cornerStyle = .capsule
            configuration.showsActivityIndicator = file == .loading
            return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onEvent(.playVoice(attachment)) })
        }
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: attachment.isImage ? "photo" : "doc")
        configuration.title = attachment.filename
        configuration.subtitle = ByteCountFormatter.string(fromByteCount: Int64(attachment.bytes), countStyle: .file)
        configuration.imagePadding = 8
        configuration.showsActivityIndicator = file == .loading
        configuration.titleLineBreakMode = .byTruncatingMiddle
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onEvent(.openAttachment(attachment)) })
        button.contentHorizontalAlignment = .leading
        return button
    }

    private var tappedAttachments: [ObjectIdentifier: LeoChatAttachment] = [:]

    @objc private func imageTapped(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view, let attachment = tappedAttachments[ObjectIdentifier(view)] else { return }
        onEvent(.openAttachment(attachment))
    }

    private func linkButton(_ title: String, _ event: @escaping ((Event) -> Void) -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.contentInsets = .zero
        configuration.buttonSize = .small
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            event(onEvent)
        })
        button.contentHorizontalAlignment = .leading
        return button
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tappedAttachments = [:]
        onEvent = { _ in }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
