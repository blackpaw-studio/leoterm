import LeoFeatures
import UIKit

/// The thread's header: the agent's avatar beside its name and a status line
/// ("Needs input · dionysus").
final class ChatThreadTitleView: UIView {
    private static let diameter: CGFloat = 30
    private let disc = UIView()
    private let emoji = UILabel()
    private let symbol = UIImageView()
    private let name = UILabel()
    private let status = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        disc.layer.cornerRadius = Self.diameter / 2
        emoji.font = .systemFont(ofSize: 16)
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabel
        for label in [name, status] {
            label.lineBreakMode = .byTruncatingTail
        }

        let labels = UIStackView(arrangedSubviews: [name, status])
        labels.axis = .vertical
        labels.alignment = .leading
        let row = UIStackView(arrangedSubviews: [disc, labels])
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        for view in [emoji, symbol] {
            view.translatesAutoresizingMaskIntoConstraints = false
            disc.addSubview(view)
        }
        disc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            disc.widthAnchor.constraint(equalToConstant: Self.diameter),
            disc.heightAnchor.constraint(equalToConstant: Self.diameter),
            emoji.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            symbol.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { UIView.layoutFittingExpandedSize }

    func configure(agentName: String, agent: Agent?, daemonName: String) {
        let color = agent?.appearance?.color?.uiColor
        disc.backgroundColor = color?.withAlphaComponent(0.2) ?? .tertiarySystemFill
        emoji.text = agent?.appearance?.emoji
        emoji.isHidden = agent?.appearance?.emoji == nil
        symbol.isHidden = agent?.appearance?.emoji != nil
        symbol.image = UIImage(systemName: agentName == ChatList.assistant ? "sparkles" : "person.fill")
        symbol.tintColor = color ?? .secondaryLabel
        name.text = agentName
        status.text = [agent.map(Self.statusLine), daemonName].compactMap { $0 }.joined(separator: " · ")
        accessibilityLabel = [agentName, status.text].compactMap { $0 }.joined(separator: ", ")
    }

    static func statusLine(_ agent: Agent) -> String {
        switch agent.priority {
        case .needsInput: String(localized: "Needs input")
        case .errored: String(localized: "Error")
        case .finished: String(localized: "Finished")
        case .working: String(localized: "Working")
        case .idle: String(localized: "Idle")
        case .stopped: String(localized: "Stopped")
        }
    }
}
