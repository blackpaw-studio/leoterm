import LeoFeatures
import UIKit

/// The live strip under a chat thread's header: the last few rows of the
/// agent's terminal on a dark panel, a state dot and a hide control. Tapping
/// it opens the full terminal; when the connection failed, it retries.
final class TerminalStripView: UIView {
    enum Content: Equatable {
        case connecting
        case live(lines: [String])
        case notRunning
        case unavailable
    }

    struct Model: Equatable {
        let content: Content
        let stateText: String
    }

    var onTap: () -> Void = {}
    var onRetry: () -> Void = {}
    var onHide: () -> Void = {}

    private static let rowCount = TerminalStripLines.count
    private static let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    private let dot = UIView()
    private let title = UILabel()
    private let stateLabel = UILabel()
    private let hideButton = UIButton(configuration: .plain())
    private let rows = (0..<TerminalStripView.rowCount).map { _ in UILabel() }
    private var content = Content.connecting

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TerminalPalette.background
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        accessibilityIdentifier = "chat.strip"

        dot.layer.cornerRadius = 4
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = TerminalPalette.secondary
        title.text = String(localized: "Live")
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = TerminalPalette.secondary
        stateLabel.textAlignment = .right
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var hide = UIButton.Configuration.plain()
        hide.image = UIImage(systemName: "chevron.up")
        hide.baseForegroundColor = TerminalPalette.secondary
        hide.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        hideButton.configuration = hide
        hideButton.accessibilityLabel = String(localized: "Hide Live Terminal")
        hideButton.accessibilityIdentifier = "chat.strip.hide"
        hideButton.addAction(UIAction { [weak self] _ in self?.onHide() }, for: .primaryActionTriggered)
        hideButton.setContentHuggingPriority(.required, for: .horizontal)

        for row in rows {
            row.font = Self.font
            row.textColor = TerminalPalette.foreground
            row.lineBreakMode = .byTruncatingTail
        }
        let header = UIStackView(arrangedSubviews: [dot, title, stateLabel, hideButton])
        header.alignment = .center
        header.spacing = 6
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let body = UIStackView(arrangedSubviews: rows)
        body.axis = .vertical
        let stack = UIStackView(arrangedSubviews: [header, body])
        stack.axis = .vertical
        stack.spacing = 2
        stack.isUserInteractionEnabled = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
        // Each row holds its line's height even while empty, so the panel
        // never changes size as output arrives.
        for row in rows { row.heightAnchor.constraint(equalToConstant: Self.font.lineHeight).isActive = true }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ model: Model) {
        content = model.content
        stateLabel.text = model.stateText
        let (color, texts, dim) = presentation(model.content)
        dot.backgroundColor = color
        for (index, row) in rows.enumerated() {
            row.text = index < texts.count ? texts[index] : nil
            row.alpha = dim ? 0.45 : 1
        }
    }

    private func presentation(_ content: Content) -> (UIColor, [String], Bool) {
        switch content {
        case .connecting:
            (.systemYellow, [String(localized: "Connecting…")], true)
        case .live(let lines):
            (.systemGreen, lines, false)
        case .notRunning:
            (.systemGray, [String(localized: "Not running")], false)
        case .unavailable:
            (.systemRed, [String(localized: "Terminal unavailable"), String(localized: "Tap to retry")], false)
        }
    }

    @objc private func tapped() {
        if case .unavailable = content { onRetry() } else { onTap() }
    }
}
