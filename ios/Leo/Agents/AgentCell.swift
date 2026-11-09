import LeoKit
import UIKit

/// An Agents row. It owns its task indicator, so the 1 s progress ticks
/// update the same view in place and the spinner keeps turning, rather than
/// a new indicator replacing it on every reconfigure.
final class AgentCell: UICollectionViewListCell {
    let taskIndicator = TaskIndicatorView()
    private var accessoryShape: AccessoryShape?
    /// The text a stale task's line is fitted from, and the width it was last
    /// fitted to. The width is known only once the cell has laid out.
    private var detail: (text: String, suffix: String)?
    private var fittedWidth: CGFloat?

    /// What the trailing accessories show. Equal values leave the accessories
    /// (and their views) alone: rebuilding them on the 1 s tick would restart
    /// the spinner and swap the badge under the user's eyes.
    private struct AccessoryShape: Equatable {
        let badge: Badge?
        let hasIndicator: Bool
    }

    struct Badge: Equatable {
        let text: String
        let tint: UIColor
    }

    /// The trailing badge (needs attention), the task indicator and the
    /// disclosure chevron. The accessory list is rebuilt only when its shape
    /// changes; the indicator is updated in place.
    func setAccessories(badge: Badge?, indicator: LeoTaskIndicator?) {
        if let indicator { taskIndicator.apply(indicator) }
        let shape = AccessoryShape(badge: badge, hasIndicator: indicator != nil)
        guard shape != accessoryShape else { return }
        accessoryShape = shape
        var accessories: [UICellAccessory] = [.disclosureIndicator()]
        if indicator != nil {
            accessories.insert(.customView(configuration: .init(customView: taskIndicator, placement: .trailing(), maintainsFixedSize: true)), at: 0)
        }
        if let badge {
            // The badge is wider than the standard accessory slot, so reserve its
            // actual width (else it spills over the chevron), and give it its
            // fitted frame: a fixed-size accessory keeps the frame it has now.
            let view = BadgeView(text: badge.text, tint: badge.tint)
            view.frame.size = view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            accessories.insert(.customView(configuration: .init(customView: view, placement: .trailing(), reservedLayoutWidth: .actual, maintainsFixedSize: true)), at: 0)
        }
        self.accessories = accessories
    }

    /// The line to show for `text`: the title truncated so `suffix` stays
    /// whole, at the width the cell last laid out to (whole until then).
    func fittedDetail(_ text: String?, suffix: String?, font: UIFont) -> String? {
        // Always replaced, so a row that stops being stale stops being refitted.
        detail = text.flatMap { text in suffix.map { (text, $0) } }
        guard let text, let fittedWidth else { return text }
        return DetailLineFit.fit(text: text, suffix: suffix, font: font, width: fittedWidth)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let detail, var content = contentConfiguration as? UIListContentConfiguration,
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
