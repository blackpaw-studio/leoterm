import LeoKit
import UIKit

/// An Agents row. It owns its task indicator, so the 1 s progress ticks
/// update the same view in place and the spinner keeps turning, rather than
/// a new indicator replacing it on every reconfigure.
final class AgentCell: UICollectionViewListCell {
    let taskIndicator = TaskIndicatorView()
    private var accessoryShape: AccessoryShape?

    private struct AccessoryShape: Equatable {
        let hasBadge: Bool
        let hasIndicator: Bool
    }

    /// The trailing badge (needs attention), the task indicator and the
    /// disclosure chevron. A row with an indicator keeps its accessory list
    /// until the shape changes (rebuilding would re-add the spinner); a badge
    /// is a fresh view each time, so its rows always rebuild. The iOS gate
    /// never shows a badge and an indicator together.
    func setAccessories(needsBadge badge: BadgeView?, indicator: LeoTaskIndicator?) {
        if let indicator { taskIndicator.apply(indicator) }
        let shape = AccessoryShape(hasBadge: badge != nil, hasIndicator: indicator != nil)
        guard badge != nil || shape != accessoryShape else { return }
        accessoryShape = shape
        var accessories: [UICellAccessory] = [.disclosureIndicator()]
        if let indicator = indicator.map({ _ in taskIndicator }) {
            accessories.insert(.customView(configuration: .init(customView: indicator, placement: .trailing(), maintainsFixedSize: true)), at: 0)
        }
        if let badge { accessories.insert(.customView(configuration: .init(customView: badge, placement: .trailing())), at: 0) }
        self.accessories = accessories
    }
}
