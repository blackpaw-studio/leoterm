import CoreGraphics
import Testing

@testable import Ghostty

/// Fit / Actual Size for previewed images (B-278): fit only ever shrinks.
struct LeoImageZoomTests {
    @Test func fitShrinksButNeverEnlarges() {
        #expect(LeoImageZoom.fitMagnification(image: CGSize(width: 2000, height: 1000), viewport: CGSize(width: 500, height: 500)) == 0.25)
        #expect(LeoImageZoom.fitMagnification(image: CGSize(width: 100, height: 50), viewport: CGSize(width: 500, height: 500)) == 1)
    }

    @Test func zeroSizeIsSafe() {
        #expect(LeoImageZoom.fitMagnification(image: .zero, viewport: CGSize(width: 500, height: 500)) == 1)
        #expect(LeoImageZoom.fitMagnification(image: CGSize(width: 10, height: 10), viewport: .zero) == 1)
    }

    @Test func fitAndActualToggle() {
        let fit = LeoImageZoom()
        #expect(fit.mode == .fit)
        #expect(fit.toggled().mode == .actual)
        #expect(fit.toggled().toggled().mode == .fit)
        #expect(fit.pinched().toggled().mode == .fit)
        #expect(fit.toggled().magnification(image: CGSize(width: 2000, height: 1000), viewport: CGSize(width: 500, height: 500)) == 1)
    }

    @Test func aResizeRefitsOnlyInFitMode() {
        let image = CGSize(width: 1000, height: 1000)
        #expect(LeoImageZoom().magnificationAfterResize(image: image, viewport: CGSize(width: 250, height: 400)) == 0.25)
        #expect(LeoImageZoom().toggled().magnificationAfterResize(image: image, viewport: CGSize(width: 250, height: 400)) == nil)
        #expect(LeoImageZoom().pinched().magnificationAfterResize(image: image, viewport: CGSize(width: 250, height: 400)) == nil)
    }
}
