import Foundation
import Testing

@testable import LeoKit

struct LeoPluginInstallLinkTests {
    private static let repo = "https%3A%2F%2Fgithub.com%2Fblackpaw-studio%2Fleo-plugin-usage"

    private static func link(_ text: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: text)!
    }

    @Test func parsesLinkWithRef() throws {
        let parsed = try LeoPluginInstallLink.parse(Self.link("leo://plugin/install?url=\(Self.repo)&ref=v0.1.0")).get()

        #expect(parsed.url.absoluteString == "https://github.com/blackpaw-studio/leo-plugin-usage")
        #expect(parsed.ref == "v0.1.0")
    }

    @Test func parsesLinkWithoutRef() throws {
        let parsed = try LeoPluginInstallLink.parse(Self.link("leo://plugin/install?url=\(Self.repo)")).get()

        #expect(parsed.ref == nil)
    }

    @Test func acceptsDebugScheme() throws {
        let parsed = try LeoPluginInstallLink.parse(Self.link("leo-debug://plugin/install?url=\(Self.repo)&ref=main")).get()

        #expect(parsed.ref == "main")
    }

    @Test func acceptsUppercaseSchemeAndHost() throws {
        _ = try LeoPluginInstallLink.parse(Self.link("LEO://Plugin/install?url=\(Self.repo)")).get()
    }

    struct Rejection: CustomTestStringConvertible, Sendable {
        let name: String
        let link: String
        let expected: LeoPluginInstallLinkError
        var testDescription: String { name }
    }

    private static let repoQuery = "url=\(repo)"

    static let rejections: [Rejection] = [
        Rejection(name: "wrong scheme", link: "ghostty://plugin/install?\(repoQuery)", expected: .wrongScheme),
        Rejection(name: "wrong host", link: "leo://plugins/install?\(repoQuery)", expected: .wrongTarget),
        Rejection(name: "wrong path", link: "leo://plugin/install/?\(repoQuery)", expected: .wrongTarget),
        Rejection(name: "no path", link: "leo://plugin?\(repoQuery)", expected: .wrongTarget),
        Rejection(name: "port", link: "leo://plugin:80/install?\(repoQuery)", expected: .wrongTarget),
        Rejection(name: "credentials", link: "leo://u:p@plugin/install?\(repoQuery)", expected: .wrongTarget),
        Rejection(name: "fragment", link: "leo://plugin/install?\(repoQuery)#x", expected: .wrongTarget),
        Rejection(name: "unknown key", link: "leo://plugin/install?\(repoQuery)&foo=1", expected: .unknownKey("foo")),
        Rejection(name: "key case", link: "leo://plugin/install?URL=\(repo)", expected: .unknownKey("URL")),
        Rejection(name: "duplicate url", link: "leo://plugin/install?\(repoQuery)&\(repoQuery)", expected: .duplicateKey("url")),
        Rejection(name: "duplicate ref", link: "leo://plugin/install?\(repoQuery)&ref=a&ref=b", expected: .duplicateKey("ref")),
        Rejection(name: "missing url", link: "leo://plugin/install?ref=main", expected: .missingURL),
        Rejection(name: "no query", link: "leo://plugin/install", expected: .missingURL),
        Rejection(name: "http url", link: "leo://plugin/install?url=http%3A%2F%2Fgithub.com%2Fx", expected: .invalidURL("only https:// URLs can be installed (got http://)")),
        Rejection(
            name: "credentials in url", link: "leo://plugin/install?url=https%3A%2F%2Fu%3Ap%40github.com%2Fx",
            expected: .invalidURL("the URL must not contain credentials")),
        Rejection(name: "ref leading dash", link: "leo://plugin/install?\(repoQuery)&ref=-x", expected: .invalidRef("-x")),
        Rejection(name: "ref double dot", link: "leo://plugin/install?\(repoQuery)&ref=a..b", expected: .invalidRef("a..b")),
        Rejection(name: "ref space", link: "leo://plugin/install?\(repoQuery)&ref=a%20b", expected: .invalidRef("a b")),
        Rejection(name: "ref empty", link: "leo://plugin/install?\(repoQuery)&ref=", expected: .invalidRef("")),
        Rejection(name: "ref newline", link: "leo://plugin/install?\(repoQuery)&ref=%0A", expected: .invalidRef("\n")),
    ]

    @Test(arguments: rejections)
    func rejects(_ rejection: Rejection) {
        let result = LeoPluginInstallLink.parse(Self.link(rejection.link))

        #expect(result == .failure(rejection.expected))
    }

    @Test func everyErrorReadsAsASentence() {
        let errors: [LeoPluginInstallLinkError] = [
            .wrongScheme, .wrongTarget, .unknownKey("a"), .duplicateKey("a"), .missingURL, .invalidURL("why"), .invalidRef("a"),
        ]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
    }
}
