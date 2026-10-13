import Foundation
import Testing

@testable import LeoKit

struct LeoPushCipherTests {
    /// Sealed by Node's `crypto` (AES-256-GCM, aad `leo-push-v1`), not by
    /// CryptoKit, so it checks the wire format rather than a round trip:
    /// key = bytes 0…31, nonce = bytes 0…11.
    static let vectorKey = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    static let vectorCiphertext = """
    AAECAwQFBgcICQoLPCCgOf/U7jnpIPLm3ocnBOf0vRaUVjAQQQqV8G5LLJBgd8uS2+MouhXUEIHk6AoUzDIJ4z70mfhR8k99a7ycgIBJslj/\
    81IIaDjPTNWtT5hI+KYUE0MnAJjd86Ufgtj5opc32YZt6m7tPgSDf0MRTo5XWpvTuMybzx1K9KGnkdiDkqdzcco=
    """
    static let vectorPayload = LeoPushPayload(
        daemonID: "d-olympus", agent: "apollo", kind: "needs_input", title: "Approve the migration?", ts: 1_760_140_800
    )

    @Test func opensAVectorSealedByAnotherImplementation() throws {
        let key = try #require(LeoPushKey(base64: Self.vectorKey))
        #expect(try LeoPushCipher.open(Self.vectorCiphertext, key: key) == Self.vectorPayload)
    }

    @Test func sealedPayloadsOpenWithTheSameKey() throws {
        let key = LeoPushKey.generate()
        let sealed = try LeoPushCipher.seal(Self.vectorPayload, key: key)

        #expect(try LeoPushCipher.open(sealed, key: key) == Self.vectorPayload)
        // nonce(12) ‖ ciphertext ‖ tag(16)
        let plaintext = try JSONEncoder().encode(Self.vectorPayload)
        #expect(Data(base64Encoded: sealed)?.count == 12 + plaintext.count + 16)
    }

    @Test func aTamperedCiphertextFailsAuthentication() throws {
        let key = try #require(LeoPushKey(base64: Self.vectorKey))
        var bytes = try #require(Data(base64Encoded: Self.vectorCiphertext))
        bytes[20] ^= 0x01

        #expect(throws: LeoPushError.authenticationFailed) {
            try LeoPushCipher.open(bytes.base64EncodedString(), key: key)
        }
    }

    @Test func theWrongKeyFailsAuthentication() {
        #expect(throws: LeoPushError.authenticationFailed) {
            try LeoPushCipher.open(Self.vectorCiphertext, key: LeoPushKey.generate())
        }
    }

    @Test(arguments: ["", "not base64!", Data(count: 27).base64EncodedString()])
    func garbageIsMalformed(ciphertext: String) throws {
        let key = try #require(LeoPushKey(base64: Self.vectorKey))
        #expect(throws: LeoPushError.malformedCiphertext) { try LeoPushCipher.open(ciphertext, key: key) }
    }

    @Test func anUnknownPayloadVersionIsRejected() throws {
        let key = LeoPushKey.generate()
        let json = Data(#"{"v":2,"daemon_id":"d","agent":"a","kind":"k","title":"t","ts":1}"#.utf8)
        let sealed = try LeoPushCipher.seal(plaintext: json, key: key)

        #expect(throws: LeoPushError.unsupportedVersion(2)) { try LeoPushCipher.open(sealed, key: key) }
    }

    @Test func keysAreExactly32Bytes() throws {
        #expect(LeoPushKey(data: Data(count: 31)) == nil)
        #expect(LeoPushKey(data: Data(count: 33)) == nil)
        #expect(LeoPushKey(base64: "nope") == nil)
        let key = LeoPushKey.generate()
        #expect(Data(base64Encoded: key.base64)?.count == 32)
        #expect(LeoPushKey(base64: key.base64) == key)
        #expect(LeoPushKey.generate() != key)
    }
}

struct LeoPushNotificationTests {
    @Test func decryptsTheAlertAndReducesUserInfoToItsTarget() throws {
        let key = try #require(LeoPushKey(base64: LeoPushCipherTests.vectorKey))
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Leo", "body": "An agent needs you"], "mutable-content": 1],
            "c": LeoPushCipherTests.vectorCiphertext,
        ]

        let alert = try #require(LeoPushNotification.alert(userInfo: userInfo, key: key, pairedDaemonIDs: ["d-olympus"]))
        #expect(alert.title == "apollo")
        #expect(alert.body == "Approve the migration?")
        #expect(alert.userInfo["daemon_id"] == "d-olympus")
        #expect(alert.userInfo["agent"] == "apollo")
    }

    private static func alert(plaintext: String) throws -> LeoPushAlert {
        let key = LeoPushKey.generate()
        let sealed = try LeoPushCipher.seal(plaintext: Data(plaintext.utf8), key: key)
        return try #require(LeoPushNotification.alert(userInfo: ["c": sealed], key: key, pairedDaemonIDs: ["d"]))
    }

    private static func json(extra: String) -> String {
        #"{"v":1,"daemon_id":"d","agent":"apollo","kind":"needs_input","title":"Has a question","ts":1"# + extra + "}"
    }

    @Test func aBodyBecomesTheBannerBodyUnderTheStateLine() throws {
        let alert = try Self.alert(plaintext: Self.json(extra: #","body":"Approve the migration?""#))
        #expect(alert.title == "apollo")
        #expect(alert.subtitle == "Has a question")
        #expect(alert.body == "Approve the migration?")
    }

    @Test(arguments: ["", #","body":"""#, #","body":null"#])
    func withoutABodyTheStateLineIsTheBodyAndNothingRepeats(extra: String) throws {
        let alert = try Self.alert(plaintext: Self.json(extra: extra))
        #expect(alert.title == "apollo")
        #expect(alert.subtitle == "")
        #expect(alert.body == "Has a question")
    }

    @Test func unknownKeysAreIgnored() throws {
        let alert = try Self.alert(plaintext: Self.json(extra: #","body":"detail","future":{"x":[1]}"#))
        #expect(alert.subtitle == "Has a question")
        #expect(alert.body == "detail")
    }

    @Test func theBodyKeyIsLeftOutWhenEmptyAndRoundTripsWhenPresent() throws {
        let bare = LeoPushPayload(daemonID: "d", agent: "a", kind: "k", title: "t", ts: 1)
        let bareJSON = try #require(String(data: JSONEncoder().encode(bare), encoding: .utf8))
        #expect(!bareJSON.contains("body"))

        let detailed = LeoPushPayload(daemonID: "d", agent: "a", kind: "k", title: "t", body: "detail", ts: 1)
        let key = LeoPushKey.generate()
        #expect(try LeoPushCipher.open(LeoPushCipher.seal(detailed, key: key), key: key) == detailed)
        #expect(detailed.body == "detail")
        #expect(bare.body == "")
    }

    @Test func theInputTypeRoundTripsAndMayBeMissing() throws {
        let key = LeoPushKey.generate()
        let ask = LeoPushPayload(
            daemonID: "d", agent: "a", kind: "chat", title: "t", ts: 1, messageID: "01", messageKind: "ask", inputType: "radio"
        )
        #expect(try LeoPushCipher.open(LeoPushCipher.seal(ask, key: key), key: key) == ask)
        #expect(ask.inputType == "radio")

        let bare = LeoPushPayload(daemonID: "d", agent: "a", kind: "chat", title: "t", ts: 1)
        let bareJSON = try #require(String(data: JSONEncoder().encode(bare), encoding: .utf8))
        #expect(!bareJSON.contains("input_type"))
        #expect(try LeoPushCipher.open(LeoPushCipher.seal(bare, key: key), key: key).inputType == nil)

        let alert = try Self.alert(plaintext: Self.json(extra: #","message_id":"01","message_kind":"ask","input_type":"checkboxes""#))
        #expect(alert.chat?.inputType == "checkboxes")
    }

    @Test func noAlertWithoutCiphertextOrWithTheWrongKey() throws {
        let key = try #require(LeoPushKey(base64: LeoPushCipherTests.vectorKey))
        #expect(LeoPushNotification.alert(userInfo: ["aps": [:]], key: key, pairedDaemonIDs: ["d-olympus"]) == nil)
        #expect(LeoPushNotification.alert(userInfo: ["c": 42], key: key, pairedDaemonIDs: ["d-olympus"]) == nil)
        #expect(LeoPushNotification.alert(userInfo: ["c": LeoPushCipherTests.vectorCiphertext], key: .generate(), pairedDaemonIDs: ["d-olympus"]) == nil)
    }

    /// A daemon this phone forgot (or never paired) keeps pushing until its
    /// registration is cleaned up; its pushes stay generic.
    @Test func noAlertForADaemonThatIsntPaired() throws {
        let key = try #require(LeoPushKey(base64: LeoPushCipherTests.vectorKey))
        let userInfo: [AnyHashable: Any] = ["c": LeoPushCipherTests.vectorCiphertext]
        #expect(LeoPushNotification.alert(userInfo: userInfo, key: key, pairedDaemonIDs: ["d-other"]) == nil)
        #expect(LeoPushNotification.alert(userInfo: userInfo, key: key, pairedDaemonIDs: []) == nil)
    }

    @Test func targetComesFromTheDecryptedUserInfo() {
        #expect(LeoPushNotification.target(userInfo: ["daemon_id": "d", "agent": "a", "aps": [:]]) == LeoPushTarget(daemonID: "d", agent: "a"))
        #expect(LeoPushNotification.target(userInfo: ["daemon_id": "d"]) == nil)
        #expect(LeoPushNotification.target(userInfo: ["daemon_id": "", "agent": "a"]) == nil)
        #expect(LeoPushNotification.target(userInfo: ["c": "…"]) == nil)
    }
}

struct LeoPushRelayTests {
    @Test func registerPostsTheHexTokenAndEnvironment() throws {
        let request = try LeoPushRelay.registerRequest(
            relayURL: URL(string: "https://relay.example.dev/")!, apnsToken: Data([0x0A, 0xFF, 0x00]), environment: .sandbox
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://relay.example.dev/register")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["apns_token": "0aff00", "env": "sandbox"])
    }

    @Test func theGrantComesFromA2xx() throws {
        #expect(try LeoPushRelay.grant(status: 200, body: Data(#"{"grant":"abc.def"}"#.utf8)) == "abc.def")
        #expect(throws: LeoPushRelayError.status(429)) { try LeoPushRelay.grant(status: 429, body: Data()) }
        #expect(throws: LeoPushRelayError.malformedResponse) { try LeoPushRelay.grant(status: 200, body: Data("{}".utf8)) }
        #expect(throws: LeoPushRelayError.malformedResponse) { try LeoPushRelay.grant(status: 200, body: Data(#"{"grant":""}"#.utf8)) }
    }
}
