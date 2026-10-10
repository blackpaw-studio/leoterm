import Testing

@testable import Ghostty

/// How a tinted pill, chip or dot paints itself, selected or not.
struct LeoTintedStyleTests {
    @Test func unselectedUsesTheTintWithALowOpacityFill() {
        let light = LeoTintedStyle(tint: .purple, isSelected: false, isDark: false)
        #expect(light.content == .tint(.purple))
        #expect(light.fill == .tint(.purple))
        #expect(light.fillOpacity == 0.15)
        #expect(LeoTintedStyle(tint: .purple, isSelected: false, isDark: true).fillOpacity == 0.20)
    }

    @Test func selectedIsWhiteOnAWhiteWashInEitherAppearance() {
        for isDark in [false, true] {
            let style = LeoTintedStyle(tint: .orange, isSelected: true, isDark: isDark)
            #expect(style.content == .white)
            #expect(style.fill == .white)
            #expect(style.fillOpacity == 0.22)
        }
    }
}
