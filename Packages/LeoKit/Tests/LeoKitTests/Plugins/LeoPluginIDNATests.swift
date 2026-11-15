import Foundation
import Testing

@testable import LeoKit

struct LeoPluginIDNATests {
    @Test(arguments: [
        ("bücher", "xn--bcher-kva"), ("münchen", "xn--mnchen-3ya"), ("日本語", "xn--wgv71a119e"),
        ("ドメイン名例", "xn--eckwd4c7cu47r2wf"), ("пример", "xn--e1afmkfd"),
    ])
    func encodesKnownVectors(_ pair: (String, String)) {
        #expect(LeoPluginIDNA.asciiLabel(pair.0) == pair.1)
        #expect(LeoPluginIDNA.asciiLabel(pair.1) == pair.1)
    }

    @Test func decodeInvertsEncode() {
        for label in ["bücher", "münchen", "日本語", "пример", "a-ü-b"] {
            let encoded = LeoPluginIDNA.encode(label.lowercased().precomposedStringWithCanonicalMapping)
            #expect(encoded.flatMap(LeoPluginIDNA.decode) == label)
        }
    }

    @Test(arguments: ["xn--", "xn--a", "xn--abc-", "xn--bcher-kvb", "xn--zzzzzzzzzzzzzzzzzzzzzzzzzzzz", "ex\u{200D}ample\u{00FC}", "\u{2603}", "a\u{3002}b"])
    func refusesMalformedOrUnsafeLabels(_ label: String) {
        #expect(LeoPluginIDNA.asciiLabel(label) == nil)
    }

    @Test func aceLabelsAreNeverCaseMapped() {
        #expect(LeoPluginIDNA.asciiLabel("xn--58d") == "xn--58d")
        #expect(LeoPluginIDNA.asciiLabel("XN--58D") == "xn--58d")
        #expect(LeoPluginIDNA.asciiLabel("\u{13A0}") == "xn--58d")
        #expect(LeoPluginIDNA.asciiLabel("\u{AB70}") == "xn--kz9a")
    }

    @Test func asciiLabelsAreOnlyLowercased() {
        #expect(LeoPluginIDNA.asciiLabel("GitHub-1") == "github-1")
    }
}
