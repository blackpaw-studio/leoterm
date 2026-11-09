import LeoKit
import Testing
import UIKit

@testable import Leo

@MainActor
struct AgentCellTests {
    private func findBadge(in view: UIView) -> BadgeView? {
        if let badge = view as? BadgeView { return badge }
        return view.subviews.lazy.compactMap { findBadge(in: $0) }.first
    }

    private func laidOut(_ cell: AgentCell) -> AgentCell {
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: 60)
        cell.layoutIfNeeded()
        return cell
    }

    @Test func reconfigureKeepsTheIndicatorInPlaceSoTheSpinnerKeepsTurning() throws {
        let cell = AgentCell()
        cell.setAccessories(badge: nil, indicator: .progress(fraction: nil))
        let host = try #require(laidOut(cell).taskIndicator.superview)
        cell.setAccessories(badge: nil, indicator: .progress(fraction: nil))
        cell.setAccessories(badge: nil, indicator: .progress(fraction: 0.5))
        #expect(laidOut(cell).taskIndicator.superview === host)
    }

    @Test func indicatorGoesAwayWhenTheTaskDoes() {
        let cell = AgentCell()
        cell.setAccessories(badge: nil, indicator: .progress(fraction: nil))
        _ = laidOut(cell)
        cell.setAccessories(badge: nil, indicator: nil)
        #expect(laidOut(cell).taskIndicator.superview == nil)
    }

    @Test func needsInputBadgeKeepsItsFittedWidthSoItCannotCollapseOntoTheChevron() {
        let cell = AgentCell()
        cell.setAccessories(badge: .init(text: "Needs Input", tint: .systemOrange), indicator: nil)
        #expect((findBadge(in: laidOut(cell))?.bounds.width ?? 0) > 40)
    }

    @Test func anUnchangedBadgeIsNotRebuiltOnTheTick() throws {
        let cell = AgentCell()
        let badge = AgentCell.Badge(text: "Needs Input", tint: .systemOrange)
        cell.setAccessories(badge: badge, indicator: nil)
        let first = try #require(findBadge(in: laidOut(cell)))
        cell.setAccessories(badge: badge, indicator: nil)
        #expect(findBadge(in: laidOut(cell)) === first)
    }

    @Test func applyingAnUnchangedIndicatorLeavesTheSpinnerAlone() throws {
        let view = TaskIndicatorView()
        view.apply(.progress(fraction: nil))
        let spinner = try #require(view.subviews.compactMap { $0 as? UIActivityIndicatorView }.first)
        let before = spinner.layer.animationKeys()
        view.apply(.progress(fraction: nil))
        #expect(spinner.layer.animationKeys() == before)
    }
}
