import AppKit
import Testing

@testable import Ghostty

@MainActor
struct LeoToolbarTitleViewTests {
    @Test func theEnabledTitleIsOneAccessiblePopUpButtonWithTheTitleAsItsValue() {
        let view = LeoToolbarTitleView()
        view.apply(.init(title: "scratch", subtitle: "~/code · claude", isEnabled: true))

        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .popUpButton)
        #expect(view.accessibilityLabel() == "Agent actions")
        #expect(view.accessibilityValue() as? String == "scratch")
        #expect(view.isAccessibilityEnabled())
        for image in view.subviews.compactMap({ $0 as? NSImageView }) { #expect(!image.isAccessibilityElement()) }
    }

    @Test func withNoAgentTheTitleStaysButItsMenuIsDisabled() {
        let view = LeoToolbarTitleView()
        view.apply(.init(title: "Ghostty", subtitle: "", isEnabled: false))

        #expect(!view.isAccessibilityEnabled())
        #expect(view.hitTest(NSPoint(x: 4, y: 4)) == nil)
    }
}
