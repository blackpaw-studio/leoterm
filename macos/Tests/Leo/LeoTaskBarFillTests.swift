import Testing

@testable import Ghostty
@testable import LeoKit

/// B-354: the done bar's green read as neon on the capsule's glass.
struct LeoTaskBarFillTests {
    @Test func doneBarIsASoftGreenNotFullStrength() {
        let fill = LeoTaskBarFill(kind: .succeeded, isOnSelection: false)
        #expect(fill.hue == .green)
        #expect(fill.opacity <= 0.6)
        #expect(fill.opacity >= 0.4)
    }

    @Test func otherBarsKeepTheirStrength() {
        #expect(LeoTaskBarFill(kind: .failed, isOnSelection: false).opacity == 1)
        #expect(LeoTaskBarFill(kind: .determinate(40), isOnSelection: false).opacity == 1)
    }

    @Test func selectedRowBarStaysWhite() {
        let fill = LeoTaskBarFill(kind: .succeeded, isOnSelection: true)
        #expect(fill.hue == .white)
        #expect(fill.opacity == 1)
        #expect(LeoTaskBarFill(kind: .stale(40), isOnSelection: true).opacity == 0.5)
    }
}
