import LeoFeatures
import LeoKit
import UIKit

extension ChatBucket {
    /// The status dot's color, and the lead-in's: orange asks, blue works, green is done.
    var tint: UIColor {
        switch self {
        case .needsYou: .systemOrange
        case .working: .systemBlue
        case .done: .systemGreen
        }
    }

    var label: String {
        switch self {
        case .needsYou: String(localized: "Needs you")
        case .working: String(localized: "Working")
        case .done: String(localized: "Done")
        }
    }
}

extension ChatPreviewPrefix {
    var text: String {
        switch self {
        case .asks: String(localized: "Asks:")
        case .error: String(localized: "Error:")
        }
    }
}

/// One inbox row: avatar with status dot, name and time, preview and unread badge.
struct ChatInboxConfiguration: UIContentConfiguration, Equatable {
    let row: ChatRow
    var now = Date()

    func makeContentView() -> any UIView & UIContentView { ChatInboxContentView(configuration: self) }

    func updated(for state: any UIConfigurationState) -> ChatInboxConfiguration { self }

    /// What VoiceOver reads for the row.
    var accessibilityText: String {
        [
            row.ref.name, row.bucket?.label, row.previewPrefix?.text,
            row.lastMessage.map(ChatPresentation.preview) ?? String(localized: "No messages yet"),
            row.unread > 0 ? String(localized: "\(row.unread) unread") : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}

private final class ChatInboxContentView: UIView, UIContentView {
    private let avatar = ChatAvatarView()
    private let name = UILabel()
    private let time = UILabel()
    private let preview = UILabel()
    private let badgeSlot = UIView()
    private var badge: BadgeView?
    var configuration: any UIContentConfiguration {
        didSet { apply() }
    }

    init(configuration: ChatInboxConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        name.adjustsFontForContentSizeCategory = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.font = .preferredFont(forTextStyle: .subheadline)
        time.textColor = .secondaryLabel
        time.adjustsFontForContentSizeCategory = true
        time.setContentHuggingPriority(.required, for: .horizontal)
        preview.font = .preferredFont(forTextStyle: .subheadline)
        preview.textColor = .secondaryLabel
        preview.numberOfLines = 2
        preview.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.adjustsFontForContentSizeCategory = true
        badgeSlot.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        badgeSlot.setContentCompressionResistancePriority(.required, for: .horizontal)

        let top = UIStackView(arrangedSubviews: [name, time])
        top.spacing = 8
        let bottom = UIStackView(arrangedSubviews: [preview, badgeSlot])
        bottom.spacing = 8
        bottom.alignment = .center
        let text = UIStackView(arrangedSubviews: [top, bottom])
        text.axis = .vertical
        text.spacing = 3
        let row = UIStackView(arrangedSubviews: [avatar, text])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
        ])
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 0)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func apply() {
        guard let configuration = configuration as? ChatInboxConfiguration else { return }
        let row = configuration.row
        avatar.configure(row)
        name.text = row.daemonName.map { "\(row.ref.name) · \($0)" } ?? row.ref.name
        name.font = .preferredFont(forTextStyle: .headline).withWeight(row.unread > 0 ? .bold : .semibold)
        time.text = row.lastMessage.map { ChatPresentation.time($0.ts, now: configuration.now) }
        preview.attributedText = Self.previewText(row)
        badge?.removeFromSuperview()
        badge = nil
        if row.unread > 0 {
            let badge = BadgeView(text: "\(row.unread)", tint: .tintColor)
            badge.translatesAutoresizingMaskIntoConstraints = false
            badgeSlot.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: badgeSlot.leadingAnchor),
                badge.trailingAnchor.constraint(equalTo: badgeSlot.trailingAnchor),
                badge.topAnchor.constraint(equalTo: badgeSlot.topAnchor),
                badge.bottomAnchor.constraint(equalTo: badgeSlot.bottomAnchor),
            ])
            self.badge = badge
        }
        badgeSlot.isHidden = row.unread == 0
    }

    private static func previewText(_ row: ChatRow) -> NSAttributedString {
        let body = row.lastMessage.map(ChatPresentation.preview) ?? String(localized: "No messages yet")
        let text = NSMutableAttributedString()
        if let prefix = row.previewPrefix {
            text.append(NSAttributedString(string: "\(prefix.text) ", attributes: [.foregroundColor: UIColor.systemOrange, .font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)]))
        }
        text.append(NSAttributedString(string: body, attributes: [.foregroundColor: row.previewPrefix == nil ? UIColor.secondaryLabel : UIColor.label]))
        return text
    }
}

/// The agent's emoji (or a symbol) on its appearance color, with the status dot on the corner.
final class ChatAvatarView: UIView {
    static let diameter: CGFloat = 46
    private static let dotDiameter: CGFloat = 13
    private let disc = UIView()
    private let emoji = UILabel()
    private let symbol = UIImageView()
    private let ring = UIView()
    private let dot = UIView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        disc.layer.cornerRadius = Self.diameter / 2
        emoji.font = .systemFont(ofSize: 24)
        symbol.contentMode = .scaleAspectFit
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        ring.backgroundColor = .secondarySystemGroupedBackground
        for view in [disc, emoji, symbol, ring, dot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let ringDiameter = Self.dotDiameter + 5
        ring.layer.cornerRadius = ringDiameter / 2
        dot.layer.cornerRadius = Self.dotDiameter / 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            disc.leadingAnchor.constraint(equalTo: leadingAnchor),
            disc.trailingAnchor.constraint(equalTo: trailingAnchor),
            disc.topAnchor.constraint(equalTo: topAnchor),
            disc.bottomAnchor.constraint(equalTo: bottomAnchor),
            emoji.centerXAnchor.constraint(equalTo: centerXAnchor),
            emoji.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: ringDiameter),
            ring.heightAnchor.constraint(equalToConstant: ringDiameter),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 2),
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: ChatRow) {
        let color = row.agent?.appearance?.color?.uiColor
        disc.backgroundColor = color?.withAlphaComponent(0.2) ?? .tertiarySystemFill
        let glyph = row.agent?.appearance?.emoji
        emoji.text = glyph
        emoji.isHidden = glyph == nil
        symbol.isHidden = glyph != nil
        symbol.image = UIImage(systemName: row.ref.name == ChatList.assistant ? "sparkles" : "person.fill")
        symbol.tintColor = color ?? .secondaryLabel
        dot.backgroundColor = row.bucket?.tint
        dot.isHidden = row.bucket == nil
        ring.isHidden = row.bucket == nil
    }
}
