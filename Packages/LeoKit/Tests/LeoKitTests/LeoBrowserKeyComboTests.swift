import Testing

@testable import LeoKit

struct LeoBrowserKeyComboTests {
    @Test func aBareNamedKeyHasNoModifiers() throws {
        let combo = try #require(LeoBrowserKeyCombo("Enter"))
        #expect(combo.key == "Enter")
        #expect(combo.modifiers.isEmpty)
    }

    @Test func modifiersPrecedeTheKey() throws {
        let combo = try #require(LeoBrowserKeyCombo("Meta+a"))
        #expect(combo.key == "a")
        #expect(combo.modifiers == [.meta])
        let many = try #require(LeoBrowserKeyCombo("Control+Shift+ArrowLeft"))
        #expect(many.key == "ArrowLeft")
        #expect(many.modifiers == [.control, .shift])
    }

    @Test func namesAndModifiersAreCaseInsensitiveAndAliased() throws {
        #expect(LeoBrowserKeyCombo("cmd+A") == LeoBrowserKeyCombo("Meta+A"))
        #expect(LeoBrowserKeyCombo("ctrl+c") == LeoBrowserKeyCombo("Control+c"))
        #expect(LeoBrowserKeyCombo("option+x") == LeoBrowserKeyCombo("Alt+x"))
        #expect(try #require(LeoBrowserKeyCombo("escape")).key == "Escape")
        #expect(try #require(LeoBrowserKeyCombo("esc")).key == "Escape")
        #expect(try #require(LeoBrowserKeyCombo("return")).key == "Enter")
        #expect(try #require(LeoBrowserKeyCombo("f5")).key == "F5")
        #expect(try #require(LeoBrowserKeyCombo(" ")).key == " ")
        #expect(try #require(LeoBrowserKeyCombo("Space")).key == " ")
    }

    @Test func aPlusKeyIsAllowedAsTheFinalKey() throws {
        let plain = try #require(LeoBrowserKeyCombo("+"))
        #expect(plain.key == "+")
        let chord = try #require(LeoBrowserKeyCombo("Meta++"))
        #expect(chord.key == "+")
        #expect(chord.modifiers == [.meta])
    }

    @Test func aSingleCharacterKeepsItsCase() throws {
        #expect(try #require(LeoBrowserKeyCombo("A")).key == "A")
        #expect(try #require(LeoBrowserKeyCombo("é")).key == "é")
    }

    @Test(arguments: ["", "Meta+", "Shift", "Meta+Shift", "Hyper+a", "Foo", "Meta+Enter+a", "F13", "+a"])
    func invalidCombosAreRejected(_ text: String) {
        #expect(LeoBrowserKeyCombo(text) == nil)
    }
}
