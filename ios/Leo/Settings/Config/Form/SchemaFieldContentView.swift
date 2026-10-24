import LeoKit
import UIKit

/// One schema field as a list cell: its label and control, with the help
/// beneath, then the warning, then any errors. A known type gets a standard
/// control; an unknown one is shown read-only.
struct SchemaFieldContentConfiguration: UIContentConfiguration {
    var row: LeoConfigFormRow
    var cronPreview: LeoCronPreviewResult?
    var handlers: SchemaFieldHandlers

    func makeContentView() -> UIView & UIContentView {
        SchemaFieldContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SchemaFieldContentConfiguration { self }
}

/// What a control reads when it acts: the row it shows now and the owner's
/// handlers, so one control survives the row updating under it.
@MainActor
final class SchemaFieldContext {
    var row: LeoConfigFormRow
    var cronPreview: LeoCronPreviewResult?
    var handlers: SchemaFieldHandlers

    init(_ configuration: SchemaFieldContentConfiguration) {
        row = configuration.row
        cronPreview = configuration.cronPreview
        handlers = configuration.handlers
    }

    func emit(_ value: LeoConfigValue) {
        handlers.edit(row.path, value)
    }
}

final class SchemaFieldContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        get { current }
        set {
            guard let newValue = newValue as? SchemaFieldContentConfiguration else { return }
            current = newValue
        }
    }

    private var current: SchemaFieldContentConfiguration {
        didSet { apply() }
    }

    private let context: SchemaFieldContext
    private var control: SchemaFieldControl?
    private var controlKind: String?

    private let dirtyDot = UIView()
    private let titleLabel = UILabel()
    private let header = UIStackView()
    private let cronPreview = UILabel()
    private let helpLabel = UILabel()
    private let warningLabel = UILabel()
    private let stack = UIStackView()
    private var errorLabels: [UILabel] = []

    init(configuration: SchemaFieldContentConfiguration) {
        current = configuration
        context = SchemaFieldContext(configuration)
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: layout

    private func build() {
        dirtyDot.accessibilityIdentifier = "field.dirty"
        dirtyDot.backgroundColor = .tintColor
        dirtyDot.layer.cornerRadius = 3
        NSLayoutConstraint.activate([
            dirtyDot.widthAnchor.constraint(equalToConstant: 6), dirtyDot.heightAnchor.constraint(equalToConstant: 6),
        ])

        titleLabel.accessibilityIdentifier = "field.label"
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)

        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        header.addArrangedSubview(dirtyDot)
        header.addArrangedSubview(titleLabel)

        configure(cronPreview, id: "field.cronPreview", style: .footnote)
        configure(helpLabel, id: "field.help", style: .footnote)
        configure(warningLabel, id: "field.warning", style: .footnote)
        helpLabel.textColor = .secondaryLabel

        // No empty stack in here: a view with no intrinsic height soaks up
        // whatever height a list asks for and the cell sizes to infinity.
        [header, cronPreview, helpLabel, warningLabel].forEach(stack.addArrangedSubview)
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
    }

    private func configure(_ label: UILabel, id: String, style: UIFont.TextStyle) {
        label.accessibilityIdentifier = id
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
    }

    // MARK: content

    private func apply() {
        context.row = current.row
        context.cronPreview = current.cronPreview
        context.handlers = current.handlers
        let row = current.row

        titleLabel.text = row.field.label
        dirtyDot.isHidden = !row.isDirty
        setControl(for: row.control)
        control?.update()
        showCronPreview(row)
        helpLabel.text = row.field.help
        helpLabel.isHidden = row.field.help.isEmpty
        showWarning(row.field.warning)
        showErrors(row.errors)
        isAccessibilityElement = false
        titleLabel.accessibilityTraits = row.isDirty ? [.staticText, .selected] : .staticText
    }

    private func setControl(for kind: LeoConfigControl) {
        let key = SchemaFieldControls.kind(of: kind)
        guard key != controlKind else { return }
        control?.view.removeFromSuperview()
        let built = SchemaFieldControls.make(kind, context: context)
        header.addArrangedSubview(built.view)
        control = built
        controlKind = key
    }

    private func showCronPreview(_ row: LeoConfigFormRow) {
        guard row.control == .cron, let preview = current.cronPreview else {
            cronPreview.isHidden = true
            return
        }
        cronPreview.isHidden = false
        switch preview {
        case .valid(let text):
            cronPreview.text = text
            cronPreview.textColor = .secondaryLabel
            cronPreview.accessibilityLabel = nil
        case .invalid(let reason):
            cronPreview.text = reason
            cronPreview.textColor = .systemRed
            cronPreview.accessibilityLabel = "Error: \(reason)"
        }
    }

    private func showWarning(_ warning: String) {
        warningLabel.isHidden = warning.isEmpty
        guard !warning.isEmpty else { return }
        let icon = NSTextAttachment(image: UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.systemOrange) ?? UIImage())
        let text = NSMutableAttributedString(attachment: icon)
        text.append(NSAttributedString(string: " " + warning))
        text.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: NSRange(location: 0, length: text.length))
        warningLabel.attributedText = text
    }

    private func showErrors(_ errors: [String]) {
        for label in errorLabels {
            stack.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        errorLabels = errors.map { message in
            let label = UILabel()
            configure(label, id: "field.error", style: .footnote)
            label.text = message
            label.textColor = .systemRed
            label.accessibilityLabel = "Error: \(message)"
            stack.addArrangedSubview(label)
            return label
        }
    }
}
