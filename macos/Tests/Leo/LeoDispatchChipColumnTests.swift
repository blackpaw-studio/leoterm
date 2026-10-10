import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-275: dispatch names line up in one column per depth, so the role chip
/// sits in a fixed-width column whatever role it shows.
@MainActor struct LeoDispatchChipColumnTests {
    private func chip(_ role: String) -> LeoDispatchRowPresentation.RoleChip {
        LeoDispatchRowPresentation.RoleChip(
            text: LeoDispatchRowPresentation.family(of: role), tint: LeoDispatchRowPresentation.roleTint(role))
    }

    private func width(of view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    @Test(arguments: ["plan", "explore", "implement.hard", "review.concurrency", String(repeating: "x", count: 40)] as [String?] + [nil])
    func everyChipSlotHasTheSameWidth(role: String?) {
        let slot = LeoRoleChipSlot(chip: role.map(chip), isSelected: false)

        #expect(width(of: slot) == LeoDispatchRowMetrics.chipColumnWidth)
    }

    @Test(arguments: LeoDispatchRowMetrics.knownFamilies)
    func everyKnownFamilyFitsUntruncated(family: String) {
        let natural = width(of: LeoRoleChipView(chip: chip(family), isSelected: false))

        #expect(natural <= LeoDispatchRowMetrics.chipColumnWidth, "\(family) needs \(natural)")
    }
}
