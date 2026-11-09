import LeoKit
import Testing
import UIKit

@testable import Leo

@MainActor
struct AgentCellTests {
    private func laidOut(_ cell: AgentCell) -> AgentCell {
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: 60)
        cell.layoutIfNeeded()
        return cell
    }

    @Test func reconfigureKeepsTheIndicatorInPlaceSoTheSpinnerKeepsTurning() throws {
        let cell = AgentCell()
        cell.setAccessories(needsBadge: nil, indicator: .progress(fraction: nil))
        let host = try #require(laidOut(cell).taskIndicator.superview)
        cell.setAccessories(needsBadge: nil, indicator: .progress(fraction: nil))
        cell.setAccessories(needsBadge: nil, indicator: .progress(fraction: 0.5))
        #expect(laidOut(cell).taskIndicator.superview === host)
    }

    @Test func indicatorGoesAwayWhenTheTaskDoes() {
        let cell = AgentCell()
        cell.setAccessories(needsBadge: nil, indicator: .progress(fraction: nil))
        _ = laidOut(cell)
        cell.setAccessories(needsBadge: nil, indicator: nil)
        #expect(laidOut(cell).taskIndicator.superview == nil)
    }

    @Test func needsInputBadgeKeepsItsFittedWidthSoItCannotCollapseOntoTheChevron() {
        let cell = AgentCell()
        let badge = BadgeView(text: "Needs Input", tint: .systemOrange)
        cell.setAccessories(needsBadge: badge, indicator: nil)
        _ = laidOut(cell)
        #expect(badge.bounds.width > 40)
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
