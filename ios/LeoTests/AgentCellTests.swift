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

    /// A cell in a window, where trait overrides resolve.
    private func hosted() -> (AgentCell, UIWindow) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        let cell = AgentCell()
        window.addSubview(cell)
        window.isHidden = false
        return (cell, window)
    }

    @Test func aTextSizeChangeRemeasuresTheBadgeInsteadOfKeepingItsPinnedFrame() throws {
        let (cell, window) = hosted()
        defer { window.isHidden = true }
        let badge = AgentCell.Badge(text: "Needs Input", tint: .systemOrange)
        cell.setAccessories(badge: badge, indicator: nil)
        let first = try #require(findBadge(in: laidOut(cell)))
        cell.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        cell.setAccessories(badge: badge, indicator: nil)
        let second = try #require(findBadge(in: laidOut(cell)))
        #expect(second !== first)
    }

    @Test func theCellRemeasuresItselfWhenTheTextSizeChanges() throws {
        let (cell, window) = hosted()
        defer { window.isHidden = true }
        cell.setAccessories(badge: .init(text: "Needs Input", tint: .systemOrange), indicator: nil)
        let first = try #require(findBadge(in: laidOut(cell)))
        cell.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        let second = try #require(findBadge(in: laidOut(cell)))
        #expect(second !== first)
    }

    @Test func accessibilityTextSizesDropTheBadgeSoTheTitleKeepsTheRow() {
        let (cell, window) = hosted()
        defer { window.isHidden = true }
        cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        cell.setAccessories(badge: .init(text: "Needs Input", tint: .systemOrange), indicator: nil)
        #expect(findBadge(in: laidOut(cell)) == nil)
    }

    @Test func accessibilityTextSizesKeepTheTaskIndicator() {
        let (cell, window) = hosted()
        defer { window.isHidden = true }
        cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        cell.setAccessories(badge: .init(text: "Needs Input", tint: .systemOrange), indicator: .progress(fraction: 0.5))
        #expect(laidOut(cell).taskIndicator.superview != nil)
    }

    @Test func aLongBadgeIsCappedSoTheTitleKeepsItsRoom() throws {
        let cell = AgentCell()
        _ = laidOut(cell)
        cell.setAccessories(badge: .init(text: "Needs Input Needs Input Needs Input", tint: .systemOrange), indicator: nil)
        let width = try #require(findBadge(in: laidOut(cell))).bounds.width
        #expect(width <= cell.bounds.width * AgentCell.badgeWidthFraction)
    }

    @Test func aBadgeThatFitsKeepsItsFittedWidth() throws {
        let cell = AgentCell()
        _ = laidOut(cell)
        cell.setAccessories(badge: .init(text: "Idle", tint: .systemIndigo), indicator: nil)
        let width = try #require(findBadge(in: laidOut(cell))).bounds.width
        #expect(width > 20 && width < cell.bounds.width * AgentCell.badgeWidthFraction)
    }

    @Test func aTaskDetailLineWrapsOnlyAtAccessibilityTextSizes() {
        let (cell, window) = hosted()
        defer { window.isHidden = true }
        #expect(cell.detailLineLimit(hasTask: true) == 1)
        #expect(cell.detailLineLimit(hasTask: false) == 2)
        cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        _ = laidOut(cell)
        #expect(cell.detailLineLimit(hasTask: true) == 0)
        #expect(cell.detailLineLimit(hasTask: false) == 2)
    }

    @Test func switchingToAnAccessibilitySizeRewrapsTheDetailLine() throws {
        let (cell, window) = hosted()
        defer { window.isHidden = true }
        var content = UIListContentConfiguration.subtitleCell()
        content.text = "beta"
        content.secondaryText = "image export · no update for 18m"
        content.secondaryTextProperties.numberOfLines = cell.detailLineLimit(hasTask: true)
        cell.contentConfiguration = content
        cell.setAccessories(badge: nil, indicator: nil)
        _ = laidOut(cell)
        cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        _ = laidOut(cell)
        let lines = (cell.contentConfiguration as? UIListContentConfiguration)?.secondaryTextProperties.numberOfLines
        #expect(lines == 0)
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
