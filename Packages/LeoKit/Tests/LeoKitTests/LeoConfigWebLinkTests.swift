import Foundation
import Testing

@testable import LeoKit

struct LeoConfigWebLinkTests {
    private func web(_ values: [String: LeoConfigValue]) -> LeoConfigDocument {
        LeoConfigDocument(revision: "r", values: values)
    }

    @Test func thePublicURLWinsAndTheLinkPointsAtTheConfigPages() {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string("https://leo.example.com/"), .string("https://other.example.com")])])
        #expect(LeoConfigWebLink.url(web: document) == URL(string: "https://leo.example.com/config"))
    }

    @Test func aPublicURLPathIsKept() {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string("https://leo.example.com/leo/")])])
        #expect(LeoConfigWebLink.url(web: document) == URL(string: "https://leo.example.com/leo/config"))
    }

    @Test(arguments: ["ftp://leo.example.com", "not a url", "", "javascript:alert(1)", "//leo.example.com"])
    func aPublicURLThatIsNotHTTPIsSkipped(bad: String) {
        let document = web(["enabled": .bool(true), "public_urls": .list([.string(bad)]), "bind": .string("10.0.2.10"), "port": .int(8370)])
        #expect(LeoConfigWebLink.url(web: document) == URL(string: "http://10.0.2.10:8370/config"))
    }

    @Test func aRoutableBindAndPortWorkWithoutAPublicURL() {
        let document = web(["enabled": .bool(true), "bind": .string("10.0.2.10"), "port": .int(9000)])
        #expect(LeoConfigWebLink.url(web: document) == URL(string: "http://10.0.2.10:9000/config"))
    }

    @Test func thePortDefaultsTo8370() {
        #expect(LeoConfigWebLink.url(web: web(["enabled": .bool(true), "bind": .string("10.0.2.10")])) == URL(string: "http://10.0.2.10:8370/config"))
    }

    @Test(arguments: ["127.0.0.1", "127.0.1.1", "localhost", "::1", "LOCALHOST"])
    func aLoopbackBindHasNoLink(bind: String) {
        let document = web(["enabled": .bool(true), "bind": .string(bind), "port": .int(8370)])
        #expect(LeoConfigWebLink.url(web: document) == nil)
        #expect(LeoConfigWebLink.url(web: document, machineHost: "dionysus.lan") == nil)
    }

    @Test func aMissingBindIsTheLoopbackDefault() {
        #expect(LeoConfigWebLink.url(web: web(["enabled": .bool(true)])) == nil)
    }

    @Test(arguments: ["0.0.0.0", "::"])
    func aWildcardBindNeedsTheMachinesHost(bind: String) {
        let document = web(["enabled": .bool(true), "bind": .string(bind), "port": .int(8370)])
        #expect(LeoConfigWebLink.url(web: document) == nil)
        #expect(LeoConfigWebLink.url(web: document, machineHost: "dionysus.lan") == URL(string: "http://dionysus.lan:8370/config"))
    }

    @Test func anIPv6AddressIsBracketed() {
        let document = web(["enabled": .bool(true), "bind": .string("2001:db8::1"), "port": .int(8370)])
        #expect(LeoConfigWebLink.url(web: document) == URL(string: "http://[2001:db8::1]:8370/config"))
    }

    @Test func aDisabledWebUIHasNoLink() {
        let document = web(["enabled": .bool(false), "public_urls": .list([.string("https://leo.example.com")]), "bind": .string("10.0.2.10")])
        #expect(LeoConfigWebLink.url(web: document) == nil)
    }

    @Test func noWebDocumentMeansNoLink() {
        #expect(LeoConfigWebLink.url(web: nil) == nil)
    }
}
