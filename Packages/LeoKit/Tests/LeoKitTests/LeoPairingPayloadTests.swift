import Foundation
import Testing

@testable import LeoKit

struct LeoPairingPayloadTests {
    @Test func parsesTheJSONThatLeoPairPrints() throws {
        let text = """

          {"daemon_id":"d-123","name":"dionysus","urls":["https://leo.example.com","http://10.0.2.10:8370"],"pairing_code":"abc"}

        """
        let payload = try LeoPairingPayload.parse(text)
        #expect(payload.daemonID == "d-123")
        #expect(payload.name == "dionysus")
        #expect(payload.urls.map(\.absoluteString) == ["https://leo.example.com", "http://10.0.2.10:8370"])
        #expect(payload.pairingCode == "abc")
    }

    @Test(arguments: [
        "",
        "not json",
        #"{"daemon_id":"d","name":"n","urls":["https://a"]}"#,
        #"{"daemon_id":"","name":"n","urls":["https://a"],"pairing_code":"c"}"#,
        #"{"daemon_id":"d","name":"n","urls":["https://a"],"pairing_code":"  "}"#,
    ])
    func rejectsMalformedPayloads(_ text: String) {
        #expect(throws: LeoPairingError.malformed) { try LeoPairingPayload.parse(text) }
    }

    @Test func dropsURLsThatAreNotHTTPOrigins() throws {
        let payload = try LeoPairingPayload.parse(
            #"{"daemon_id":"d","name":"n","urls":["ftp://a","nope","http://10.0.0.1:8370"],"pairing_code":"c"}"#
        )
        #expect(payload.urls.map(\.absoluteString) == ["http://10.0.0.1:8370"])
    }

    @Test func requiresAtLeastOneUsableURL() {
        #expect(throws: LeoPairingError.noUsableURL) {
            try LeoPairingPayload.parse(#"{"daemon_id":"d","name":"n","urls":["ftp://a"],"pairing_code":"c"}"#)
        }
    }

    @Test func fallsBackToTheDaemonIDWhenNameIsBlank() throws {
        let payload = try LeoPairingPayload.parse(#"{"daemon_id":"d","name":"","urls":["http://a:1"],"pairing_code":"c"}"#)
        #expect(payload.name == "d")
    }
}
