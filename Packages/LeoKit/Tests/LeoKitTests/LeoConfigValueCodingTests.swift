import Foundation
import Testing

@testable import LeoKit

struct LeoConfigValueCodingTests {
    private func decode(_ json: String) throws -> LeoConfigValue {
        try JSONDecoder().decode(LeoConfigValue.self, from: Data(json.utf8))
    }

    private func encode(_ value: LeoConfigValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try #require(String(bytes: try encoder.encode(value), encoding: .utf8))
    }

    @Test func aNullIntIsNotZero() throws {
        #expect(try decode("null") == .null)
        #expect(try decode("0") == .int(0))
        #expect(try decode("null") != .int(0))
        #expect(try encode(.null) == "null")
        #expect(try encode(.int(0)) == "0")
    }

    @Test func aBoolIsNotAnInt() throws {
        #expect(try decode("true") == .bool(true))
        #expect(try decode("1") == .int(1))
        #expect(try decode("2.5") == .double(2.5))
    }

    @Test func listsAndMapsRoundTrip() throws {
        let list = LeoConfigValue.list([.string("a"), .string("b")])
        let map = LeoConfigValue.map(["FOO": "bar", "EMPTY": ""])
        #expect(try decode(try encode(list)) == list)
        #expect(try decode(try encode(map)) == map)
        #expect(try decode(#"["a","b"]"#) == list)
        #expect(try decode(#"{"FOO":"bar","EMPTY":""}"#) == map)
    }

    @Test func aNestedObjectKeepsItsMixedValues() throws {
        let object = try decode(#"{"enabled":null,"allow":["x"],"n":3}"#)
        #expect(object == .object(["enabled": .null, "allow": .list([.string("x")]), "n": .int(3)]))
        #expect(try decode(try encode(object)) == object)
    }

    @Test func aSecretDecodesAsSetOrNotSet() throws {
        #expect(try decode(#"{"set":true}"#) == .secret(isSet: true))
        #expect(try decode(#"{"set":false}"#) == .secret(isSet: false))
    }

    @Test func aSecretNeverEncodesAValue() throws {
        #expect(try encode(.secret(isSet: true)) == #"{"set":true}"#)
        #expect(try encode(.secret(isSet: false)) == #"{"set":false}"#)
    }

    @Test func aMapWithASetKeyIsNotASecret() throws {
        #expect(try decode(#"{"set":"yes"}"#) == .map(["set": "yes"]))
    }

    @Test func secretEditsEncodeAsReplaceOrClear() throws {
        #expect(try encode(.secretReplace("s3cret")) == #"{"replace":"s3cret"}"#)
        #expect(try encode(.secretClear) == #"{"clear":true}"#)
        #expect(try decode(#"{"replace":"s3cret"}"#) == .secretReplace("s3cret"))
        #expect(try decode(#"{"clear":true}"#) == .secretClear)
    }

    @Test func accessorsReadTheCommonShapes() {
        #expect(LeoConfigValue.string("x").stringValue == "x")
        #expect(LeoConfigValue.int(3).intValue == 3)
        #expect(LeoConfigValue.bool(true).boolValue == true)
        #expect(LeoConfigValue.null.isNull)
        #expect(LeoConfigValue.int(3).stringValue == nil)
    }

    // MARK: env maps with secret values

    private static let secretEnv = #"{"ANTHROPIC_AUTH_TOKEN":{"set":true},"ANTHROPIC_BASE_URL":"http://localhost:3325"}"#

    @Test func anEnvMapWithASecretVariableKeepsBothKinds() throws {
        let env = try decode(Self.secretEnv)

        #expect(env.envEntries == ["ANTHROPIC_BASE_URL": "http://localhost:3325"])
        #expect(env.envSecretNames == ["ANTHROPIC_AUTH_TOKEN"])
    }

    @Test func editingThePlainEntriesKeepsTheSecretVariables() throws {
        let edited = try decode(Self.secretEnv).replacingEnvEntries(["ANTHROPIC_BASE_URL": "http://other", "NEW": "1"])

        #expect(edited.envEntries == ["ANTHROPIC_BASE_URL": "http://other", "NEW": "1"])
        #expect(edited.envSecretNames == ["ANTHROPIC_AUTH_TOKEN"])
        #expect(try decode(try encode(edited)) == edited)
        #expect(try encode(edited).contains(#""ANTHROPIC_AUTH_TOKEN":{"set":true}"#))
    }

    @Test func aPlainEnvMapStaysAPlainMapAndAnEmptyOneIsEmpty() throws {
        #expect(LeoConfigValue.map(["A": "1"]).replacingEnvEntries(["B": "2"]) == .map(["B": "2"]))
        #expect(LeoConfigValue.null.replacingEnvEntries([:]) == .map([:]))
        #expect(LeoConfigValue.map([:]).envSecretNames.isEmpty)
    }

    @Test func aSecretVariableTheUserReusesTheNameOfIsReplacedByTheirEntry() throws {
        let edited = try decode(Self.secretEnv).replacingEnvEntries(["ANTHROPIC_AUTH_TOKEN": "typed"])

        #expect(edited.envSecretNames.isEmpty)
        #expect(edited == .map(["ANTHROPIC_AUTH_TOKEN": "typed"]))
    }

    @Test func aSecretVariableReadsAsSetAndShowsItsPendingChange() throws {
        let env = try decode(Self.secretEnv)
        let token = "ANTHROPIC_AUTH_TOKEN"

        #expect(env.envSecrets == [token: .set])
        #expect(env.settingEnvSecret(token, to: .secretReplace("new")).envSecrets == [token: .replacing])
        #expect(env.settingEnvSecret(token, to: .secretClear).envSecrets == [token: .clearing])
        #expect(env.settingEnvSecret(token, to: .secretClear).settingEnvSecret(token, to: .secret(isSet: true)) == env)
    }

    @Test func replacingASecretVariableSendsTheStringAndClearingSendsNull() throws {
        let env = try decode(Self.secretEnv)
        let token = "ANTHROPIC_AUTH_TOKEN"

        let replaced = try encode(env.settingEnvSecret(token, to: .secretReplace("s3cret")).writeForm)
        #expect(replaced.contains(#""ANTHROPIC_AUTH_TOKEN":"s3cret""#))
        #expect(!replaced.contains("replace"))
        #expect(try encode(env.settingEnvSecret(token, to: .secretClear).writeForm).contains(#""ANTHROPIC_AUTH_TOKEN":null"#))
        #expect(try encode(env.writeForm).contains(#""ANTHROPIC_AUTH_TOKEN":{"set":true}"#))
        #expect(try encode(LeoConfigValue.secretReplace("x").writeForm) == #"{"replace":"x"}"#)
    }

    @Test func aPendingSecretSurvivesEditingThePlainEntries() throws {
        let pending = try decode(Self.secretEnv).settingEnvSecret("ANTHROPIC_AUTH_TOKEN", to: .secretReplace("new"))
        let edited = pending.replacingEnvEntries(["X": "1"])

        #expect(edited.envSecrets == ["ANTHROPIC_AUTH_TOKEN": .replacing])
        #expect(edited.envEntries == ["X": "1"])
    }
}
