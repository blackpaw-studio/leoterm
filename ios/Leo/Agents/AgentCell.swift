import LeoKit
import UIKit

/// An Agents row. It owns its task indicator, so the 1 s progress ticks
/// update the same view in place and the spinner keeps turning, rather than
/// a new indicator replacing it on every reconfigure.
final class AgentCell: UICollectionViewListCell {
    /// The most of the row a badge may take; the title and detail keep the rest.
    static let badgeWidthFraction: CGFloat = 0.35

    let taskIndicator = TaskIndicatorView()
    private var accessoryShape: AccessoryShape?
    private var accessoryContent: (badge: Badge?, indicator: LeoTaskIndicator?)?
    /// The text a stale task's line is fitted from, and the width it was last
    /// fitted to. The width is known only once the cell has laid out.
    private var detail: (text: String, suffix: String)?
    private var fittedWidth: CGFloat?
    private var hasTaskDetail = false

    /// What the trailing accessories show. Equal values leave the accessories
    /// (and their views) alone: rebuilding them on the 1 s tick would restart
    /// the spinner and swap the badge under the user's eyes.
    private struct AccessoryShape: Equatable {
        let badge: Badge?
        let hasIndicator: Bool
        /// The badge's frame is measured once and pinned, so a text size or
        /// row width change must rebuild it.
        let sizeCategory: UIContentSizeCategory
        /// The widest the badge may be; 0 until the cell has a width.
        let badgeMaxWidth: CGFloat
    }

    struct Badge: Equatable {
        let text: String
        let tint: UIColor
    }

    /// The trailing badge (needs attention), the task indicator and the
    /// disclosure chevron. The accessory list is rebuilt only when its shape
    /// changes; the indicator is updated in place.
    func setAccessories(badge: Badge?, indicator: LeoTaskIndicator?) {
        accessoryContent = (badge, indicator)
        if let indicator { taskIndicator.apply(indicator) }
        let shape = shape(badge: badge, hasIndicator: indicator != nil)
        guard shape != accessoryShape else { return }
        accessoryShape = shape
        var accessories: [UICellAccessory] = [.disclosureIndicator()]
        if indicator != nil {
            accessories.insert(.customView(configuration: .init(customView: taskIndicator, placement: .trailing(), maintainsFixedSize: true)), at: 0)
        }
        if let badge = shape.badge {
            // The badge is wider than the standard accessory slot, so reserve its
            // actual width (else it spills over the chevron), and give it its
            // fitted frame, capped so the title keeps its room: a fixed-size
            // accessory keeps the frame it has now.
            let view = BadgeView(text: badge.text, tint: badge.tint)
            var size = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            if shape.badgeMaxWidth > 0 { size.width = min(size.width, shape.badgeMaxWidth) }
            view.frame.size = size
            accessories.insert(.customView(configuration: .init(customView: view, placement: .trailing(), reservedLayoutWidth: .actual, maintainsFixedSize: true)), at: 0)
        }
        self.accessories = accessories
    }

    /// At accessibility text sizes there is no room for a badge: the title and
    /// detail line take the row, and the status dot and the detail line say
    /// the same thing.
    private func shape(badge: Badge?, hasIndicator: Bool) -> AccessoryShape {
        let category = traitCollection.preferredContentSizeCategory
        return AccessoryShape(
            badge: category.isAccessibilityCategory ? nil : badge,
            hasIndicator: hasIndicator,
            sizeCategory: category,
            badgeMaxWidth: (bounds.width * Self.badgeWidthFraction).rounded(.down)
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (cell: AgentCell, _) in
            guard let content = cell.accessoryContent else { return }
            cell.setAccessories(badge: content.badge, indicator: content.indicator)
            cell.refreshDetail()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The line to show for `text`: the title truncated so `suffix` stays
    /// whole, at the width the cell last laid out to (whole until then).
    func fittedDetail(_ text: String?, suffix: String?, font: UIFont) -> String? {
        // Always replaced, so a row that stops being stale stops being refitted.
        detail = text.flatMap { text in suffix.map { (text, $0) } }
        // A wrapped line has the room: no title truncation to keep the suffix whole.
        guard let text, let fittedWidth, !isAccessibilitySize else { return text }
        return DetailLineFit.fit(text: text, suffix: suffix, font: font, width: fittedWidth)
    }

    private var isAccessibilitySize: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    /// How many lines the detail line gets (0 is unlimited). A task's line is
    /// one line, tail-truncated, so it cannot grow the row; at accessibility
    /// text sizes it wraps in full instead (a task title is short), as it
    /// cannot fit on one line there.
    func detailLineLimit(hasTask: Bool) -> Int {
        hasTaskDetail = hasTask
        guard hasTask else { return 2 }
        return isAccessibilitySize ? 0 : 1
    }

    /// Re-applies the line limit and the fit after a text size change.
    private func refreshDetail() {
        guard var content = contentConfiguration as? UIListContentConfiguration else { return }
        content.secondaryTextProperties.numberOfLines = detailLineLimit(hasTask: hasTaskDetail)
        if let detail {
            fittedWidth = nil
            content.secondaryText = isAccessibilitySize ? detail.text : content.secondaryText
        }
        contentConfiguration = content
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The badge's cap follows the row's width, known only once laid out.
        if let content = accessoryContent, shape(badge: content.badge, hasIndicator: content.indicator != nil) != accessoryShape {
            setAccessories(badge: content.badge, indicator: content.indicator)
        }
        guard let detail, !isAccessibilitySize, var content = contentConfiguration as? UIListContentConfiguration,
              let width = secondaryTextWidth, width != fittedWidth else { return }
        fittedWidth = width
        let fitted = DetailLineFit.fit(text: detail.text, suffix: detail.suffix, font: content.secondaryTextProperties.font, width: width)
        guard content.secondaryText != fitted else { return }
        content.secondaryText = fitted
        contentConfiguration = content
    }

    /// The room for the secondary text: from where its label starts to the
    /// content view's trailing margin. Not the label's own width, which
    /// shrinks with its text and would feed back into the fit. The secondary
    /// label is the lower of the two the list lays out (zero-sized until the
    /// first real layout).
    private var secondaryTextWidth: CGFloat? {
        let labels = contentView.subviews.compactMap { $0 as? UILabel }.filter { !$0.frame.isEmpty }
        guard let secondary = labels.max(by: { $0.frame.minY < $1.frame.minY }), labels.count > 1 else { return nil }
        let width = contentView.bounds.width - secondary.frame.minX - contentView.directionalLayoutMargins.trailing
        return width > 0 ? width : nil
    }
}
