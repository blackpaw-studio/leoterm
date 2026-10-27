import Foundation
import Testing

@testable import LeoKit

/// The picker's emoji: the fully-qualified Unicode set with CLDR names and
/// keywords, plus the daemon's single-grapheme rule.
struct LeoEmojiCatalogTests {
    private let catalog = LeoEmojiCatalog.standard

    @Test func holdsTheFullyQualifiedSet() {
        #expect(catalog.unicodeVersion == "15.1")
        #expect(catalog.entries.count == 3773)
        #expect(catalog.groups.first?.name == "Smileys & Emotion")
        #expect(!catalog.groups.map(\.name).contains("Component"))
        #expect(catalog.entries.allSatisfy { LeoEmoji.isSingleGrapheme($0.emoji) })
    }

    @Test func searchMatchesNamesFirst() {
        #expect(catalog.search("classical").first?.emoji == "🏛️")
        #expect(catalog.search("ROCKET").first?.emoji == "🚀")
        #expect(catalog.search("red heart").first?.emoji == "❤️")
    }

    @Test func searchMatchesCLDRKeywords() {
        // "top hat" is named for its shape; "tophat" is only a keyword.
        #expect(catalog.search("tophat").map(\.emoji).contains("🎩"))
        #expect(catalog.search("hat").map(\.emoji).contains("🎩"))
    }

    @Test func searchSkipsSkinTonesUnlessAsked() {
        let waving = catalog.search("waving hand").map(\.emoji)
        #expect(waving.contains("👋"))
        #expect(!waving.contains("👋🏽"))
        #expect(catalog.search("waving hand medium skin tone").map(\.emoji).contains("👋🏽"))
    }

    @Test func emptyQueryFindsNothing() {
        #expect(catalog.search("").isEmpty)
        #expect(catalog.search("   ").isEmpty)
        #expect(catalog.search("zzqxj").isEmpty)
    }

    @Test func groupsHoldOnlyBaseEmoji() {
        let people = catalog.groups.first { $0.name == "People & Body" }
        #expect(people?.entries.map(\.emoji).contains("👋") == true)
        #expect(people?.entries.map(\.emoji).contains("👋🏽") == false)
    }

    @Test func frequentPutsRecentPicksFirst() {
        let row = catalog.frequent(recent: ["🦊", "🏛️", "🦊", "not an emoji"], limit: 6)
        #expect(row.count == 6)
        #expect(Array(row.map(\.emoji).prefix(2)) == ["🦊", "🏛️"])
        #expect(Set(row.map(\.emoji)).count == row.count)
        #expect(catalog.frequent(recent: [], limit: 4).count == 4)
    }

    @Test func validatorAcceptsOneGraphemeOnly() {
        #expect(LeoEmoji.isSingleGrapheme("👨‍👩‍👧‍👦"))
        #expect(LeoEmoji.isSingleGrapheme("🇺🇸"))
        #expect(LeoEmoji.isSingleGrapheme("👋🏽"))
        #expect(LeoEmoji.isSingleGrapheme("1️⃣"))
        #expect(!LeoEmoji.isSingleGrapheme("🎩🎩"))
        #expect(!LeoEmoji.isSingleGrapheme(""))
        // One grapheme, but far past the daemon's 64-byte cap.
        #expect(!LeoEmoji.isSingleGrapheme("e" + String(repeating: "\u{301}", count: 40)))
    }
}
