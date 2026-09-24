import Testing

@testable import Ghostty

/// B-009: the sidebar filter's pure fuzzy matcher and ranker.
struct LeoSidebarFuzzyMatchTests {
    // MARK: Matching tiers

    @Test func exactMatchIgnoresCase() {
        let match = LeoFuzzyMatcher.match("LEO", in: "leo")
        #expect(match?.tier == .exact)
        #expect(match?.offsets == [0, 1, 2])
    }

    @Test func prefixMatch() {
        let match = LeoFuzzyMatcher.match("bra", in: "brand")
        #expect(match?.tier == .prefix)
        #expect(match?.offsets == [0, 1, 2])
    }

    @Test(arguments: [
        ("web-app", "app", 4),
        ("web_app", "app", 4),
        ("web.app", "app", 4),
        ("web app", "app", 4),
        ("webApp", "app", 3),
    ])
    func wordBoundaryMatchAfterSeparatorOrCamelHump(candidate: String, query: String, start: Int) {
        let match = LeoFuzzyMatcher.match(query, in: candidate)
        #expect(match?.tier == .wordBoundary)
        #expect(match?.offsets == Array(start..<(start + query.count)))
    }

    @Test func wordBoundaryPrefersTheBoundaryOccurrenceOverAnEarlierMidWordOne() {
        // "ap" occurs mid-word at 1 ("map") and at the "-app" boundary at 4.
        let match = LeoFuzzyMatcher.match("ap", in: "map-app")
        #expect(match?.tier == .wordBoundary)
        #expect(match?.offsets == [4, 5])
    }

    @Test func contiguousSubstringMatch() {
        let match = LeoFuzzyMatcher.match("ran", in: "brand")
        #expect(match?.tier == .substring)
        #expect(match?.offsets == [1, 2, 3])
    }

    @Test func scatteredSubsequenceMatch() {
        let match = LeoFuzzyMatcher.match("bnd", in: "brand")
        #expect(match?.tier == .subsequence)
        #expect(match?.offsets == [0, 3, 4])
    }

    @Test func noMatchWhenOutOfOrderOrMissing() {
        #expect(LeoFuzzyMatcher.match("dnb", in: "brand") == nil)
        #expect(LeoFuzzyMatcher.match("x", in: "brand") == nil)
        #expect(LeoFuzzyMatcher.match("brandy", in: "brand") == nil)
    }

    @Test func caseInsensitiveAcrossUnicode() {
        #expect(LeoFuzzyMatcher.match("ÉCOLE", in: "école")?.tier == .exact)
        #expect(LeoFuzzyMatcher.match("Ö", in: "zöe")?.tier == .substring)
        #expect(LeoFuzzyMatcher.match("ΣΟΦ", in: "σοφία")?.tier == .prefix)
    }

    @Test func offsetsCountGraphemesNotScalars() {
        // "é" as e + combining acute is one Character.
        let name = "cafe\u{301}-bot"
        let match = LeoFuzzyMatcher.match("bot", in: name)
        #expect(match?.tier == .wordBoundary)
        #expect(match?.offsets == [5, 6, 7])
    }

    // MARK: Expanding case folds (one character folds to several)

    @Test func foldedMultiCharacterQueryMatchesAnExpandingCharacter() {
        // "ß" folds to "ss": the query spans one name character.
        let match = LeoFuzzyMatcher.match("ss", in: "straße")
        #expect(match?.tier == .substring)
        #expect(match?.offsets == [4])
    }

    @Test func expandingQueryCharacterMatchesItsFoldedSpelling() {
        let match = LeoFuzzyMatcher.match("ß", in: "strasse")
        #expect(match?.tier == .substring)
        #expect(match?.offsets == [4, 5])
    }

    @Test func ligatureMatchesItsLetters() {
        #expect(LeoFuzzyMatcher.match("file", in: "ﬁle") == .init(tier: .exact, offsets: [0, 1, 2]))
        #expect(LeoFuzzyMatcher.match("fil", in: "ﬁle") == .init(tier: .prefix, offsets: [0, 1]))
    }

    @Test func wordBoundaryCountsFromTheStartOfAnExpandingCharacter() {
        let match = LeoFuzzyMatcher.match("ssx", in: "web-ßx")
        #expect(match?.tier == .wordBoundary)
        #expect(match?.offsets == [4, 5])
    }

    @Test func subsequenceAcrossAnExpandingCharacterBoldsWholeCharacters() {
        let match = LeoFuzzyMatcher.match("sx", in: "ßax")
        #expect(match?.tier == .subsequence)
        #expect(match?.offsets == [0, 2])
    }

    @Test func emojiNamesMatchByCharacter() {
        let match = LeoFuzzyMatcher.match("🚀x", in: "🚀-x")
        #expect(match?.tier == .subsequence)
        #expect(match?.offsets == [0, 2])
    }

    @Test func tiersAreOrderedBestFirst() {
        let order: [LeoFuzzyMatcher.Tier] = [.exact, .prefix, .wordBoundary, .substring, .subsequence]
        #expect(order.sorted() == order)
    }

    // MARK: Ranking rows

    @Test func emptyOrWhitespaceQueryLeavesTheListUnchanged() {
        let rows = [row("zeta"), row("alpha"), row("mid")]
        #expect(LeoFuzzyMatcher.rank(rows, query: "") == rows)
        #expect(LeoFuzzyMatcher.rank(rows, query: "   ") == rows)
    }

    @Test func noMatchYieldsAnEmptyList() {
        #expect(LeoFuzzyMatcher.rank([row("alpha"), row("beta")], query: "zzz").isEmpty)
    }

    @Test func ranksExactThenPrefixThenBoundaryThenSubstringThenScattered() {
        let scattered = row("a-p-p-x")
        let substring = row("xappx")
        let boundary = row("web-app")
        let prefix = row("apple")
        let exact = row("App")
        let none = row("zzz")
        let ranked = LeoFuzzyMatcher.rank([scattered, substring, none, boundary, prefix, exact], query: "app")
        #expect(ranked.map(\.name) == ["App", "apple", "web-app", "xappx", "a-p-p-x"])
    }

    @Test func tiesKeepTheIncomingSidebarOrder() {
        let rows = [row("zeta-app"), row("alpha-app"), row("mid-app")]
        #expect(LeoFuzzyMatcher.rank(rows, query: "app").map(\.name) == ["zeta-app", "alpha-app", "mid-app"])
    }

    @Test func queryIsTrimmedBeforeMatching() {
        #expect(LeoFuzzyMatcher.rank([row("brand")], query: "  bra \n").map(\.name) == ["brand"])
    }

    @Test func templateMatchesCountButLoseTiesToNameMatches() {
        let byTemplate = row("zeta", template: "swift")
        let byName = row("swift")
        let ranked = LeoFuzzyMatcher.rank([byTemplate, byName], query: "swift")
        #expect(ranked.map(\.name) == ["swift", "zeta"])
    }

    @Test func aBetterTemplateTierOutranksAWorseNameTier() {
        let scatteredName = row("s-w-i-f-t")
        let exactTemplate = row("zeta", template: "swift")
        let ranked = LeoFuzzyMatcher.rank([scatteredName, exactTemplate], query: "swift")
        #expect(ranked.map(\.name) == ["zeta", "s-w-i-f-t"])
    }

    @Test func highlightOffsetsComeFromTheNameOnly() {
        #expect(LeoFuzzyMatcher.nameHighlights(for: row("brand"), query: "bnd") == [0, 3, 4])
        #expect(LeoFuzzyMatcher.nameHighlights(for: row("zeta", template: "swift"), query: "swift").isEmpty)
        #expect(LeoFuzzyMatcher.nameHighlights(for: row("brand"), query: "").isEmpty)
    }

    // MARK: Highlight runs

    @Test func highlightRunsSplitTheNameIntoBoldAndPlainPieces() {
        let runs = LeoFuzzyMatcher.highlightRuns(name: "brand", offsets: [0, 3, 4])
        #expect(runs == [.init(text: "b", isMatched: true), .init(text: "ra", isMatched: false), .init(text: "nd", isMatched: true)])
    }

    @Test func highlightRunsWithoutOffsetsIsOnePlainRun() {
        #expect(LeoFuzzyMatcher.highlightRuns(name: "brand", offsets: []) == [.init(text: "brand", isMatched: false)])
    }

    private func row(_ name: String, template: String? = nil) -> LeoAgentRow {
        LeoAgentRow(host: .local, name: name, template: template, status: .running, activity: .idle, actionDetail: nil)
    }
}
