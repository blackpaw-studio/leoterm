import LeoFeatures
import UIKit

/// The agent's brief at the top of its chat thread: one line while collapsed
/// (the status, else the goal), every row when expanded. Tapping the top line
/// toggles; the owner decides what "expanded" means and re-renders.
final class ChatBriefHeaderView: UIView {
    var onToggle: (() -> Void)?

    private let toggle = UIButton(configuration: .plain())
    private let rows = UIStackView()
    private let separator = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .label
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        configuration.titleLineBreakMode = .byTruncatingTail
        toggle.configuration = configuration
        toggle.contentHorizontalAlignment = .fill
        toggle.accessibilityIdentifier = "chat.brief.toggle"
        toggle.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)

        rows.axis = .vertical
        rows.spacing = 6
        rows.isLayoutMarginsRelativeArrangement = true
        rows.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 12, right: 16)
        rows.accessibilityIdentifier = "chat.brief.rows"

        separator.backgroundColor = .separator
        let stack = UIStackView(arrangedSubviews: [toggle, rows, separator])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(rows brief: [AgentBriefRow], isExpanded: Bool) {
        var configuration = toggle.configuration ?? .plain()
        let summary = brief.first { $0.kind == .status } ?? brief.first { $0.kind == .goal }
        configuration.attributedTitle = AttributedString(
            summary?.text ?? String(localized: "Brief"),
            attributes: AttributeContainer([.font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.medium)])
        )
        configuration.image = UIImage(systemName: isExpanded ? "chevron.up" : "chevron.down")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        toggle.configuration = configuration
        toggle.accessibilityLabel = String(localized: "Brief")
        toggle.accessibilityValue = isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        toggle.accessibilityHint = isExpanded ? String(localized: "Collapses the brief") : String(localized: "Expands the brief")

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows.isHidden = !isExpanded
        guard isExpanded else { return }
        for row in brief { rows.addArrangedSubview(Self.label(for: row)) }
    }

    private static func label(for row: AgentBriefRow) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        let body = UIFont.preferredFont(forTextStyle: .footnote)
        if row.kind == .updated {
            label.font = .preferredFont(forTextStyle: .caption1)
            label.textColor = row.isMuted ? .tertiaryLabel : .secondaryLabel
            label.text = row.text
            return label
        }
        let text = NSMutableAttributedString(
            string: row.kind.title.uppercased() + "  ",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .caption2).withWeight(.semibold), .foregroundColor: UIColor.secondaryLabel]
        )
        text.append(NSAttributedString(string: row.text, attributes: [.font: body, .foregroundColor: UIColor.label]))
        label.attributedText = text
        return label
    }
}
