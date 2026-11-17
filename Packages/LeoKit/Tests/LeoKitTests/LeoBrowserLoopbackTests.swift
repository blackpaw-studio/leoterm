import Foundation
import Testing

@testable import LeoKit

/// B-305: a page on the agent's machine's localhost can't load on iPhone
/// (no SSH forward there): navigation refuses it with a plain error naming
/// the machine, and every other host passes unchanged.
@MainActor
struct LeoBrowserLoopbackTests {
    private let mapping = LeoLoopbackRefusingURLMapping(machine: "dionysus")

    @Test(arguments: [
        "http://localhost:5173/", "http://LOCALHOST/app", "http://127.0.0.1:8080", "http://127.4.5.6/",
        "http://[::1]:3000/x", "https://app.localhost/", "http://0.0.0.0:8000/",
    ])
    func refusesLoopbackWithPlainError(_ url: String) async throws {
        do {
            _ = try await mapping.toLocal(try #require(URL(string: url)))
            Issue.record("expected \(url) to be refused")
        } catch let error as LeoBrowserError {
            #expect(error.code == .localhostUnreachable)
            #expect(error.message.contains("dionysus's localhost"))
        }
    }

    @Test(arguments: ["http://192.168.1.20:5173/", "https://example.com/", "http://dionysus.local:8080/", "http://10.0.2.10/", "about:blank"])
    func passesLANAndPublicHosts(_ url: String) async throws {
        let parsed = try #require(URL(string: url))
        #expect(try await mapping.toLocal(parsed) == parsed)
        #expect(mapping.toRemote(parsed) == parsed)
    }

    @Test func onlyTheForwardableHostsCountAsLoopbackForTheMac() throws {
        let forwardable = ["http://localhost:1/", "http://127.0.0.1:1/", "http://[::1]:1/"]
        let machineOnly = ["http://127.0.0.2:1/", "http://app.localhost:1/", "http://0.0.0.0:1/"]
        for url in forwardable {
            let parsed = try #require(URL(string: url))
            #expect(LeoBrowserLoopback.isLoopback(parsed))
            #expect(LeoBrowserLoopback.isMachineLocal(parsed))
        }
        for url in machineOnly {
            let parsed = try #require(URL(string: url))
            #expect(!LeoBrowserLoopback.isLoopback(parsed))
            #expect(LeoBrowserLoopback.isMachineLocal(parsed))
        }
    }
}
