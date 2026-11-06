import CoreGraphics
import Testing

@testable import LeoKit

struct LeoChatImageLayoutTests {
    typealias Layout = LeoChatImageLayout

    @Test func aTallNarrowImageKeepsABubbleWideEnoughToRead() {
        #expect(Layout.displaySize(for: CGSize(width: 400, height: 4000)) == CGSize(width: 130, height: 260))
        #expect(Layout.displaySize(for: CGSize(width: 100, height: 2000)) == CGSize(width: 100, height: 200))
        #expect(Layout.displaySize(for: CGSize(width: 40, height: 200)) == CGSize(width: 40, height: 80))
    }

    @Test func aWideImageFitsTheMaxWidth() {
        #expect(Layout.displaySize(for: CGSize(width: 1000, height: 500)) == CGSize(width: 260, height: 130))
    }

    @Test func aSmallImageIsNotScaledUp() {
        #expect(Layout.displaySize(for: CGSize(width: 80, height: 60)) == CGSize(width: 80, height: 60))
    }

    @Test func anEmptyImageHasNoSize() {
        #expect(Layout.displaySize(for: .zero) == .zero)
    }
}
