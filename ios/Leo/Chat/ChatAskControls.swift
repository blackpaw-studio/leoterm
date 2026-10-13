import LeoFeatures
import LeoKit
import UIKit

/// An open prompt's answer controls, by input type: buttons that answer
/// at once, a radio or checkbox list with Submit, a free-text field (alone,
/// or under the choices with `allow_text`) with a character counter.
///
/// The text view outlives reconfiguration: the thread reconfigures every
/// cell on each state change, and rebuilding a focused text view would drop
/// the keyboard on every keystroke.
final class ChatAskControls: UIStackView, UITextViewDelegate {
    struct Model {
        let message: LeoChatMessage
        let input: LeoChatInput
        let draft: LeoChatAskDraft
        let isAnswering: Bool
    }

    private static let maximumTextHeight: CGFloat = 180

    var onEvent: (ChatMessageCell.Event) -> Void = { _ in }

    private let textBox = UIView()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private var messageID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        spacing = 8
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .tertiarySystemFill
        textView.layer.cornerRadius = 10
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityIdentifier = "chat.ask.text"
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
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
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            textView.heightAnchor.constraint(lessThanOrEqualToConstant: Self.maximumTextHeight),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 11),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -11),
        ])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ model: Model) {
        syncText(model)
        arrangedSubviews.filter { $0 !== textBox }.forEach { $0.removeFromSuperview() }
        let input = model.input
        let takesText = input.kind == .text || input.allowsText
        if takesText {
            if textBox.superview !== self { addArrangedSubview(textBox) }
        } else {
            textBox.removeFromSuperview()
        }
        // The text box, when kept, is the only arranged view left: the
        // choices go above it, the counter and Submit below.
        let above = [hint(for: input), choices(model)].compactMap { $0 }
        for (index, view) in above.enumerated() { insertArrangedSubview(view, at: index) }
        if takesText { addArrangedSubview(counter(model.draft)) }
        if let submit = submitButton(model) { addArrangedSubview(submit) }
    }

    /// Takes the draft's text unless the user is typing in this field.
    private func syncText(_ model: Model) {
        if model.message.id != messageID {
            messageID = model.message.id
            if textView.isFirstResponder { textView.resignFirstResponder() }
            textView.text = model.draft.text
        } else if !textView.isFirstResponder, textView.text != model.draft.text {
            textView.text = model.draft.text
        }
        textView.isEditable = !model.isAnswering
        placeholder.text = model.input.placeholder ?? (model.input.kind == .text ? String(localized: "Answer") : String(localized: "Or answer in your own words"))
        updateTextLayout()
    }

    private func updateTextLayout() {
        placeholder.isHidden = !textView.text.isEmpty
        let width = textView.bounds.width > 0 ? textView.bounds.width : 260
        let fitting = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        textView.isScrollEnabled = fitting > Self.maximumTextHeight
    }

    func textViewDidChange(_ textView: UITextView) {
        updateTextLayout()
        onEvent(.text(textView.text))
    }

    // MARK: Pieces

    private func hint(for input: LeoChatInput) -> UIView? {
        guard input.kind == .checkboxes else { return nil }
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.text = switch (input.min, input.max) {
        case let (min, max) where min == max: String(localized: "Choose \(min)")
        case (0, let max): String(localized: "Choose up to \(max)")
        case let (min, max): String(localized: "Choose \(min)–\(max)")
        }
        return label
    }

    private func choices(_ model: Model) -> UIView? {
        let options = model.input.options
        guard !options.isEmpty else { return nil }
        let row = UIStackView()
        row.spacing = 8
        if model.input.kind == .buttons {
            row.axis = options.count > 2 ? .vertical : .horizontal
            row.distribution = .fillEqually
            for option in options { row.addArrangedSubview(answerButton(option, model: model)) }
        } else {
            row.axis = .vertical
            row.spacing = 2
            for option in options { row.addArrangedSubview(selectionRow(option, model: model)) }
        }
        return row
    }

    private func answerButton(_ option: LeoChatOption, model: Model) -> UIButton {
        let isDeny = model.message.kind == .permission && option.value == "deny"
        var configuration = isDeny ? UIButton.Configuration.bordered() : UIButton.Configuration.borderedProminent()
        configuration.title = option.label
        configuration.cornerStyle = .capsule
        configuration.showsActivityIndicator = model.isAnswering
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onEvent(.choice(option.value)) })
        button.isEnabled = !model.isAnswering
        button.accessibilityIdentifier = "chat.ask.option.\(option.value)"
        return button
    }

    /// A radio or checkbox row: the mark, then the label.
    private func selectionRow(_ option: LeoChatOption, model: Model) -> UIButton {
        let isSelected = model.draft.selected.contains(option.value)
        let isRadio = model.input.kind == .radio
        let symbol = switch (isRadio, isSelected) {
        case (true, true): "checkmark.circle.fill"
        case (true, false): "circle"
        case (false, true): "checkmark.square.fill"
        case (false, false): "square"
        }
        var configuration = UIButton.Configuration.plain()
        configuration.title = option.label
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 10
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        configuration.baseForegroundColor = .label
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in isSelected ? .tintColor : .tertiaryLabel }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onEvent(.choice(option.value)) })
        button.contentHorizontalAlignment = .leading
        button.isEnabled = !model.isAnswering
        button.accessibilityIdentifier = "chat.ask.option.\(option.value)"
        button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        return button
    }

    private func counter(_ draft: LeoChatAskDraft) -> UILabel {
        let label = UILabel()
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .right
        let remaining = draft.remainingTextScalars
        label.textColor = remaining < 0 ? .systemRed : .secondaryLabel
        label.text = String(localized: "\(draft.text.unicodeScalars.count)/\(LeoChatAnswer.maxTextScalars)")
        return label
    }

    /// Buttons answer by themselves; Submit appears when there is a
    /// selection or text to send.
    private func submitButton(_ model: Model) -> UIButton? {
        guard model.input.kind != .buttons || model.input.allowsText else { return nil }
        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = String(localized: "Submit")
        configuration.cornerStyle = .capsule
        configuration.showsActivityIndicator = model.isAnswering
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.textView.resignFirstResponder()
            self?.onEvent(.submit)
        })
        button.isEnabled = !model.isAnswering && model.draft.answer(for: model.input) != nil
        button.accessibilityIdentifier = "chat.ask.submit"
        return button
    }
}
