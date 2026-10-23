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
}
