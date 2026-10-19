import LeoFeatures
import LeoKit
import UIKit

/// An AskUserQuestion card: per question a small caps header, the question,
/// radio rows (single choice) or checkbox rows (several), an "Other…" text
/// field, then Submit and "Answer in terminal". Once settled it shows the
/// outcome instead: one line per answer, or why there is none.
///
/// Each question's text view outlives reconfiguration, like
/// `ChatAskControls`' (the thread reconfigures every cell on each state
/// change, and rebuilding a focused text view would drop the keyboard on
/// every keystroke). The draft lives in the thread's state, so the views
/// only mirror it, and cell reuse starts them over from the new message's draft.
final class ChatQuestionsCard: UIStackView {
    struct Model {
        let message: LeoChatMessage
        let questions: [LeoChatQuestion]
        let draft: LeoChatQuestionsDraft
        let state: LeoChatQuestionsCardState
        let error: String?
        let isAnswering: Bool
    }

    static let minimumRowHeight: CGFloat = 44

    var onEvent: (ChatMessageCell.Event) -> Void = { _ in }

    private var sections: [String: Section] = [:]
    private var messageID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 16
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ model: Model) {
        if model.message.id != messageID {
            messageID = model.message.id
            sections.values.forEach { $0.textView.resignFirstResponder() }
            sections = [:]
        }
        guard case .open = model.state else {
            sections = [:]
            arrangedSubviews.forEach { $0.removeFromSuperview() }
            settledViews(model.state).forEach(addArrangedSubview)
            return
        }
        // The sections stay in place (removing a focused text view would
        // drop the keyboard); only the footer is rebuilt.
        let kept = model.questions.map { question in
            let section = sections[question.id] ?? makeSection(question)
            sections[question.id] = section
            section.configure(question, draft: model.draft, isAnswering: model.isAnswering)
            return section
        }
        arrangedSubviews.filter { view in !kept.contains { $0 === view } }.forEach { $0.removeFromSuperview() }
        for section in kept where section.superview !== self { addArrangedSubview(section) }
        addArrangedSubview(footer(model))
    }

    /// The focused text field's frame in `view`'s coordinates; nil while
    /// none is being edited.
    func focusedTextFrame(in view: UIView) -> CGRect? {
        sections.values.lazy.compactMap { $0.focusedFrame(in: view) }.first
    }

    private func makeSection(_ question: LeoChatQuestion) -> Section {
        let section = Section(questionID: question.id)
        section.onChoice = { [weak self] value in
            self?.onEvent(.questionChoice(questionID: question.id, value: value))
        }
        section.onText = { [weak self] text in self?.onEvent(.questionText(questionID: question.id, text)) }
        return section
    }

    // MARK: Footer

    private func footer(_ model: Model) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        if let error = model.error {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .systemRed
            label.numberOfLines = 0
            label.text = error
            label.accessibilityIdentifier = "chat.questions.error"
            stack.addArrangedSubview(label)
        }
        stack.addArrangedSubview(submitButton(model))
        stack.addArrangedSubview(dismissButton(model))
        return stack
    }

    private func submitButton(_ model: Model) -> UIButton {
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = String(localized: "Submit")
        configuration.cornerStyle = .capsule
        configuration.showsActivityIndicator = model.isAnswering
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.sections.values.forEach { $0.textView.resignFirstResponder() }
            self?.onEvent(.questionsSubmit)
        })
        button.isEnabled = !model.isAnswering && model.draft.isComplete
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumRowHeight).isActive = true
        button.accessibilityIdentifier = "chat.questions.submit"
        return button
    }

    private func dismissButton(_ model: Model) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = String(localized: "Answer in terminal")
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.sections.values.forEach { $0.textView.resignFirstResponder() }
            self?.onEvent(.questionsDismiss)
        })
        button.isEnabled = !model.isAnswering
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumRowHeight).isActive = true
        button.accessibilityIdentifier = "chat.questions.dismiss"
        return button
    }

    // MARK: Settled

    private func settledViews(_ state: LeoChatQuestionsCardState) -> [UIView] {
        let lines: [String]
        let isOutcome: Bool
        switch state {
        case .open: return []
        case .answered(let summary): (lines, isOutcome) = (summary, false)
        case .inTerminal: (lines, isOutcome) = ([String(localized: "Answered in terminal")], true)
        case .timedOut: (lines, isOutcome) = ([String(localized: "Timed out")], true)
        case .expired: (lines, isOutcome) = ([String(localized: "Expired")], true)
        }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        if !isOutcome { stack.addArrangedSubview(Self.settledTitle(String(localized: "Answered"))) }
        for line in lines {
            let label = UILabel()
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.font = isOutcome
                ? .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
                : .preferredFont(forTextStyle: .subheadline)
            label.textColor = isOutcome ? .secondaryLabel : .label
            label.text = line
            stack.addArrangedSubview(label)
        }
        stack.accessibilityIdentifier = "chat.questions.settled"
        return [stack]
    }

    private static func settledTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.text = text.uppercased()
        return label
    }
}

extension ChatMessageCell.Event {
    /// The thread action for an event from a questions card; nil for any other event.
    func questionsAction(messageID: String) -> ChatThread.Action? {
        switch self {
        case .questionChoice(let questionID, let value):
            .questionChoiceTapped(messageID: messageID, questionID: questionID, value: value)
        case .questionText(let questionID, let text):
            .questionTextChanged(messageID: messageID, questionID: questionID, text)
        case .questionsSubmit:
            .questionsSubmitTapped(messageID: messageID)
        case .questionsDismiss:
            .questionsDismissTapped(messageID: messageID)
        default:
            nil
        }
    }
}

// MARK: - One question

extension ChatQuestionsCard {
    /// One question's views. The text field is kept; the option rows are
    /// rebuilt on every configure (they hold no state of their own).
    final class Section: UIStackView, UITextViewDelegate {
        private static let maximumTextHeight: CGFloat = 140
        private static let minimumHeight = ChatQuestionsCard.minimumRowHeight

        let textView = UITextView()
        var onChoice: (String) -> Void = { _ in }
        var onText: (String) -> Void = { _ in }

        private let questionID: String
        private let header = UILabel()
        private let prompt = UILabel()
        private let options = UIStackView()
        private let textBox = UIView()
        private let placeholder = UILabel()
        private let limitHint = UILabel()

        init(questionID: String) {
            self.questionID = questionID
            super.init(frame: .zero)
            axis = .vertical
            spacing = 6
            header.font = .preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            header.textColor = .secondaryLabel
            prompt.font = .preferredFont(forTextStyle: .body).withWeight(.semibold)
            for label in [header, prompt, limitHint] {
                label.numberOfLines = 0
                label.adjustsFontForContentSizeCategory = true
            }
            limitHint.font = .preferredFont(forTextStyle: .footnote)
            limitHint.textColor = .systemRed
            limitHint.text = String(localized: "Too long — \(LeoChatAnswer.maxTextScalars) characters max")
            options.axis = .vertical
            options.spacing = 2
            configureTextView()
            addArrangedSubview(header)
            addArrangedSubview(prompt)
            addArrangedSubview(options)
            addArrangedSubview(textBox)
            addArrangedSubview(limitHint)
        }

        @available(*, unavailable)
        required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func configureTextView() {
            textView.font = .preferredFont(forTextStyle: .body)
            textView.adjustsFontForContentSizeCategory = true
            textView.backgroundColor = .tertiarySystemFill
            textView.layer.cornerRadius = 10
            textView.layer.cornerCurve = .continuous
            textView.textContainerInset = UIEdgeInsets(top: 12, left: 6, bottom: 12, right: 6)
            textView.isScrollEnabled = false
            textView.delegate = self
            textView.accessibilityIdentifier = "chat.questions.\(questionID).text"
            textView.accessibilityLabel = String(localized: "Other")
            placeholder.font = .preferredFont(forTextStyle: .body)
            placeholder.adjustsFontForContentSizeCategory = true
            placeholder.textColor = .placeholderText
            placeholder.text = String(localized: "Other…")
            placeholder.isAccessibilityElement = false
            for view in [textView, placeholder] {
                view.translatesAutoresizingMaskIntoConstraints = false
                textBox.addSubview(view)
            }
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: textBox.topAnchor),
                textView.bottomAnchor.constraint(equalTo: textBox.bottomAnchor),
                textView.leadingAnchor.constraint(equalTo: textBox.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: textBox.trailingAnchor),
                textView.heightAnchor.constraint(greaterThanOrEqualToConstant: ChatQuestionsCard.minimumRowHeight),
                textView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maximumTextHeight),
                placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
                placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 11),
                placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -11)
            ])
        }

        func configure(_ question: LeoChatQuestion, draft: LeoChatQuestionsDraft, isAnswering: Bool) {
            header.text = question.header.uppercased()
            header.isHidden = question.header.isEmpty
            prompt.text = question.question
            prompt.isHidden = question.question.isEmpty
            let selected = Set(draft.values(for: question.id))
            options.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for option in question.options {
                options.addArrangedSubview(row(
                    option, in: question, isSelected: selected.contains(option.value), isAnswering: isAnswering
                ))
            }
            textBox.isHidden = !question.allowsText
            let text = draft.text(for: question.id)
            if !textView.isFirstResponder, textView.text != text { textView.text = text }
            textView.isEditable = !isAnswering
            updateTextLayout()
            limitHint.isHidden = !question.allowsText || text.unicodeScalars.count <= LeoChatAnswer.maxTextScalars
        }

        /// A full-width radio or checkbox row: the mark, the label and the
        /// description under it. At least 44pt tall.
        private func row(
            _ option: LeoChatOption, in question: LeoChatQuestion, isSelected: Bool, isAnswering: Bool
        ) -> UIButton {
            let symbol = switch (question.multi, isSelected) {
            case (false, true): "largecircle.fill.circle"
            case (false, false): "circle"
            case (true, true): "checkmark.square.fill"
            case (true, false): "square"
            }
            var configuration = UIButton.Configuration.plain()
            configuration.title = option.label
            configuration.subtitle = option.description
            configuration.titleAlignment = .leading
            configuration.image = UIImage(systemName: symbol)
            configuration.imagePadding = 12
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            configuration.baseForegroundColor = .label
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in
                isSelected ? .tintColor : .tertiaryLabel
            }
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .body)
                return attributes
            }
            configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .footnote)
                attributes.foregroundColor = .secondaryLabel
                return attributes
            }
            configuration.background.cornerRadius = 10
            configuration.background.backgroundColor = isSelected ? .tintColor.withAlphaComponent(0.14) : .clear
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                // The draft clears the field when it takes an option, so stop editing first.
                self?.textView.resignFirstResponder()
                self?.onChoice(option.value)
            })
            button.contentHorizontalAlignment = .leading
            button.isEnabled = !isAnswering
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight).isActive = true
            button.accessibilityIdentifier = "chat.questions.\(question.id).option.\(option.value)"
            button.accessibilityLabel = [option.label, option.description].compactMap { $0 }.joined(separator: ", ")
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
            return button
        }

        private func updateTextLayout() {
            placeholder.isHidden = !textView.text.isEmpty
            let width = textView.bounds.width > 0 ? textView.bounds.width : 260
            let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            textView.isScrollEnabled = fitting > Self.maximumTextHeight
        }

        func focusedFrame(in view: UIView) -> CGRect? {
            textView.isFirstResponder ? textBox.convert(textBox.bounds, to: view) : nil
        }

        func textViewDidChange(_ textView: UITextView) {
            updateTextLayout()
            onText(textView.text)
        }
    }
}
