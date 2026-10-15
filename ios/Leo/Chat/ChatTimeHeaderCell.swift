import LeoKit
import UIKit

/// The centred time above a pause in the thread: "Today 1:06 PM", with the
/// day in semibold, as in iMessage.
final class ChatTimeHeaderCell: UICollectionViewCell {
    private let label = UILabel()
    private var top: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        top = label.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            top,
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(date: Date, id: String, topSpacing: CGFloat, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        top.constant = topSpacing
        let header = LeoChatTranscript.headerText(date, calendar: calendar, now: now)
        let text = NSMutableAttributedString(string: header.text)
        let day = (header.text as NSString).range(of: header.day)
        if day.location != NSNotFound {
            let font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            text.addAttribute(.font, value: font, range: day)
        }
        label.attributedText = text
        accessibilityIdentifier = "chat.timeHeader.\(id)"
    }
}
