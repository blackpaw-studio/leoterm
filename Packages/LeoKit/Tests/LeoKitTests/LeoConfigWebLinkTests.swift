import Foundation
import Testing

@testable import LeoKit

struct LeoConfigWebLinkTests {
    private func web(_ values: [String: LeoConfigValue]) -> LeoConfigDocument {
        LeoConfigDocument(revision: "r", values: values)
    }

    @Test func thePublicURLWins() {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string("https://leo.example.com/"), .string("https://other.example.com")])])
        #expect(LeoConfigWebLink.url(web: document, resource: "templates") == URL(string: "https://leo.example.com/config/templates"))
    }

    @Test(arguments: [
        ("defaults", nil, "/config/defaults"),
        ("templates", nil, "/config/templates"),
        ("templates", "my coder", "/config/templates/my%20coder"),
        ("tasks", nil, "/tasks"),
        ("tasks", "nightly", "/tasks/nightly"),
        ("environments", "base", "/config/environments"),
        ("delegation", nil, "/config/delegation"),
        ("web", nil, "/config/settings"),
        ("client", nil, "/config/settings"),
        ("hosts", "remote", "/config/settings"),
        ("service", nil, "/service"),
    ] as [(String, String?, String)])
    func eachResourceLinksToItsOwnWebPage(resource: String, item: String?, path: String) {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string("https://leo.example.com")])])
        #expect(LeoConfigWebLink.url(web: document, resource: resource, item: item) == URL(string: "https://leo.example.com" + path))
    }

    @Test func anUnknownResourceLinksToTheSiteRoot() {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string("https://leo.example.com")])])
        #expect(LeoConfigWebLink.url(web: document, resource: "teleporters") == URL(string: "https://leo.example.com"))
        #expect(LeoConfigWebLink.url(web: document) == URL(string: "https://leo.example.com"))
    }

    @Test func aPublicURLPathIsKept() {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string("https://leo.example.com/leo/")])])
        #expect(LeoConfigWebLink.url(web: document, resource: "templates") == URL(string: "https://leo.example.com/leo/config/templates"))
    }

    @Test(arguments: ["ftp://leo.example.com", "not a url", "", "javascript:alert(1)", "//leo.example.com"])
    func aPublicURLThatIsNotHTTPIsSkipped(bad: String) {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string(bad)]), "bind": .string("10.0.2.10"), "port": .int(8370)])
        #expect(LeoConfigWebLink.url(web: document, resource: "templates") == URL(string: "http://10.0.2.10:8370/config/templates"))
    }

    @Test func aRoutableBindAndPortWorkWithoutAPublicURL() {
        let document = web(["enabled": .bool(true), "bind": .string("10.0.2.10"), "port": .int(9000)])
        #expect(LeoConfigWebLink.url(web: document, resource: "templates") == URL(string: "http://10.0.2.10:9000/config/templates"))
    }

    @Test func thePortDefaultsTo8370() {
        #expect(LeoConfigWebLink.url(web: web(["enabled": .bool(true), "bind": .string("10.0.2.10")]), resource: "templates") == URL(string: "http://10.0.2.10:8370/config/templates"))
    }

    @Test(arguments: ["127.0.0.1", "127.0.1.1", "localhost", "::1", "LOCALHOST"])
    func aLoopbackBindHasNoLink(bind: String) {
        let document = web(["enabled": .bool(true), "bind": .string(bind), "port": .int(8370)])
        #expect(LeoConfigWebLink.url(web: document, resource: "templates") == nil)
        #expect(LeoConfigWebLink.url(web: document, machineHost: "dionysus.lan", resource: "templates") == nil)
    }

    @Test func aMissingBindIsTheLoopbackDefault() {
        #expect(LeoConfigWebLink.url(web: web(["enabled": .bool(true)]), resource: "templates") == nil)
    }

    @Test(arguments: ["0.0.0.0", "::"])
    func aWildcardBindNeedsTheMachinesHost(bind: String) {
        let document = web(["enabled": .bool(true), "bind": .string(bind), "port": .int(8370)])
        #expect(LeoConfigWebLink.url(web: document, resource: "templates") == nil)
        #expect(LeoConfigWebLink.url(web: document, machineHost: "dionysus.lan", resource: "templates") == URL(string: "http://dionysus.lan:8370/config/templates"))
    }

    @Test func anIPv6AddressIsBracketed() {
        let document = web(["enabled": .bool(true), "bind": .string("2001:db8::1"), "port": .int(8370)])
        #expect(LeoConfigWebLink.url(web: document, resource: "templates") == URL(string: "http://[2001:db8::1]:8370/config/templates"))
    }

    @Test func aDisabledWebUIHasNoLink() {
        let document = web(["enabled": .bool(false), "public_urls": .list([.string("https://leo.example.com")]), "bind": .string("10.0.2.10")])
        #expect(LeoConfigWebLink.url(web: document, resource: "templates") == nil)
    }

    @Test func noWebDocumentMeansNoLink() {
        #expect(LeoConfigWebLink.url(web: nil, resource: "templates") == nil)
    }

    // MARK: paired origin (iOS)

    @Test func pairedOriginBeatsBindWhenNoPublicURL() {
        let document = web(["enabled": .bool(true), "bind": .string("10.0.2.10"), "port": .int(9000)])
        let origin = URL(string: "https://leo.tailnet.ts.net:8443/")

        #expect(LeoConfigWebLink.url(web: document, resource: "templates", fallbackOrigin: origin) == URL(string: "https://leo.tailnet.ts.net:8443/config/templates"))
        #expect(LeoConfigWebLink.url(web: web(["enabled": .bool(true)]), resource: "tasks", item: "nightly", fallbackOrigin: origin) == URL(string: "https://leo.tailnet.ts.net:8443/tasks/nightly"))
    }

    @Test func thePublicURLStillBeatsThePairedOrigin() {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string("https://leo.example.com")])])

        #expect(LeoConfigWebLink.url(web: document, resource: "templates", fallbackOrigin: URL(string: "https://paired.example.com")) == URL(string: "https://leo.example.com/config/templates"))
    }

    @Test func disabledWebStillNoLink() {
        let document = web(["enabled": .bool(false), "bind": .string("10.0.2.10")])

        #expect(LeoConfigWebLink.url(web: document, resource: "templates", fallbackOrigin: URL(string: "https://paired.example.com")) == nil)
        #expect(LeoConfigWebLink.url(web: nil, resource: "templates", fallbackOrigin: URL(string: "https://paired.example.com")) == nil)
    }

    @Test func aPairedOriginThatIsNotHTTPFallsThroughToTheBind() {
        let document = web(["enabled": .bool(true), "bind": .string("10.0.2.10"), "port": .int(9000)])

        #expect(LeoConfigWebLink.url(web: document, resource: "templates", fallbackOrigin: URL(string: "ftp://paired.example.com")) == URL(string: "http://10.0.2.10:9000/config/templates"))
    }
}
