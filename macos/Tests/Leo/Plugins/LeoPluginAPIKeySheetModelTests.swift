import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

@MainActor struct LeoPluginAPIKeySheetModelTests {
    private static let deepseek = LeoPluginAPIKeyProvider(provider: "deepseek", label: "DeepSeek", host: "api.deepseek.com")
    private static let key = "sk-0123456789abcdef"

    private func model() -> LeoPluginAPIKeySheetModel {
        LeoPluginAPIKeySheetModel(provider: Self.deepseek, pluginName: "Usage")
    }

    @Test func theCopyNamesThePluginTheServiceAndTheOnlyHost() {
        let model = model()
        #expect(model.message == "Usage wants an API key for DeepSeek. It will only be sent to api.deepseek.com.")
    }

    @Test func theNameStartsAsTheProvidersLabel() {
        #expect(model().name == "DeepSeek")
    }

    @Test func aPastedKeyIsTrimmedAndAddable() throws {
        let model = model()
        model.key = "  \(Self.key)\n"
        #expect(model.canAdd)
        #expect(model.keyProblem == nil)
        let entry = try #require(model.entry())
        #expect(entry.key == Self.key)
        #expect(entry.name == "DeepSeek")
    }

    @Test(arguments: ["sk with space", "sk-ключ", String(repeating: "k", count: 513), "sk-\u{7F}"])
    func anUnusableKeyIsExplainedWithoutEchoingIt(raw: String) {
        let model = model()
        model.key = raw
        #expect(!model.canAdd)
        #expect(model.entry() == nil)
        let problem = model.keyProblem ?? ""
        #expect(!problem.isEmpty)
        #expect(!problem.contains(raw))
    }

    @Test func anEmptyKeyCannotBeAddedButIsNotAnError() {
        let model = model()
        model.key = "   "
        #expect(!model.canAdd)
        #expect(model.keyProblem == nil)
    }

    @Test func aBlankNameFallsBackToTheLabel() throws {
        let model = model()
        model.key = Self.key
        model.name = "   "
        #expect(try #require(model.entry()).name == "DeepSeek")
        model.name = "  Work  "
        #expect(try #require(model.entry()).name == "Work")
    }

    @Test(arguments: [String(repeating: "n", count: 65), "Wo\nrk", "Wo\u{7F}rk"])
    func aBadNameBlocksAdd(name: String) {
        let model = model()
        model.key = Self.key
        model.name = name
        #expect(!model.canAdd)
        #expect(model.nameProblem != nil)
    }

    @Test func aSixtyFourCharacterNameIsFine() {
        let model = model()
        model.key = Self.key
        model.name = String(repeating: "n", count: 64)
        #expect(model.canAdd)
    }
}
