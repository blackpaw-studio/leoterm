import Foundation
import Testing

@testable import LeoKit

struct LeoBrowserURLPolicyTests {
    @Test(arguments: ["http://localhost:5173/", "https://example.com/a?b=c#d", "HTTP://EXAMPLE.COM", "about:blank", "ABOUT:BLANK"])
    func allowsWebAndBlankPages(_ text: String) throws {
        let url = try LeoBrowserURLPolicy.validate(text)
        #expect(LeoBrowserURLPolicy.allows(url))
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "ftp://a.test/x", "chrome://settings", "about:srcdoc", "blob:https://a.test/1"])
    func rejectsOtherSchemesWithSchemeNotAllowed(_ text: String) {
        do {
            _ = try LeoBrowserURLPolicy.validate(text)
            Issue.record("\(text) should be rejected")
        } catch let error as LeoBrowserError {
            #expect(error.code == .schemeNotAllowed)
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func aSchemelessURLIsRejectedWithAHint() {
        do {
            _ = try LeoBrowserURLPolicy.validate("example.com/path")
            Issue.record("expected rejection")
        } catch let error as LeoBrowserError {
            #expect(error.code == .schemeNotAllowed)
            #expect(error.message.contains("http"))
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test(arguments: ["localhost:3000", "localhost:3000/app?x=1", "127.0.0.1:5173"])
    func aSchemelessHostAndPortSaysTheURLIsMissingItsScheme(_ text: String) {
        do {
            _ = try LeoBrowserURLPolicy.validate(text)
            Issue.record("\(text) should be rejected")
        } catch let error as LeoBrowserError {
            #expect(error.code == .schemeNotAllowed)
            #expect(error.message.contains("Use a full URL such as http://\(text)"))
            #expect(!error.message.contains("Scheme"))
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test(arguments: ["", "   ", "http://", "https:///path", "http://exa mple.com"])
    func malformedURLsAreInvalidArgs(_ text: String) {
        do {
            _ = try LeoBrowserURLPolicy.validate(text)
            Issue.record("\(text) should be rejected")
        } catch let error as LeoBrowserError {
            #expect(error.code == .invalidArgs)
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func surroundingWhitespaceIsTrimmed() throws {
        #expect(try LeoBrowserURLPolicy.validate("  https://a.test/ \n").absoluteString == "https://a.test/")
    }

    @Test func allowsInspectsAnyURLTheEngineReports() throws {
        #expect(!LeoBrowserURLPolicy.allows(try #require(URL(string: "file:///tmp/x"))))
        #expect(LeoBrowserURLPolicy.allows(try #require(URL(string: "https://a.test"))))
    }

    /// B-409: Open in Default Browser hands the page's URL to the system, so
    /// only a web page with a host may go: never a scheme that launches an
    /// app or names a file.
    @Test(arguments: ["http://localhost:5173/x?q#f", "https://example.com", "HTTPS://Example.com/a", "http://127.0.0.1:8080/"])
    func externallyOpenableAcceptsHTTPAndHTTPSWithAHost(_ text: String) throws {
        #expect(LeoBrowserURLPolicy.isExternallyOpenable(try #require(URL(string: text))))
    }

    @Test(arguments: [
        "about:blank", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "blob:https://a.test/1",
        "mailto:a@b.test", "x-custom://open", "ssh://host", "http:", "http:///path", "https:/nohost",
    ])
    func externallyOpenableRejectsEverythingElse(_ text: String) throws {
        #expect(!LeoBrowserURLPolicy.isExternallyOpenable(try #require(URL(string: text))))
    }
}
