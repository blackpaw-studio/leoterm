import Foundation
import Testing

@testable import LeoKit

struct LeoPluginHostPatternTests {
    static func parse(_ text: String) -> LeoPluginHostPattern? { try? LeoPluginHostPattern.parse(text) }

    @Test func anExactHostIsLowercasedAndLosesOneTrailingDot() throws {
        #expect(try LeoPluginHostPattern.parse("API.GitHub.com.") == .exact("api.github.com"))
        #expect(try LeoPluginHostPattern.parse("api.github.com").canonical == "api.github.com")
    }

    @Test func aWildcardKeepsItsSuffix() throws {
        let pattern = try LeoPluginHostPattern.parse("*.GitHubUserContent.com")
        #expect(pattern == .wildcard(suffix: "githubusercontent.com"))
        #expect(pattern.canonical == "*.githubusercontent.com")
    }

    @Test(arguments: [
        "", " ", "*", "*.", "*.com", "*.*.example.com", "a.*.example.com", "*example.com", "foo*.example.com",
        "example", "localhost", "https://example.com", "example.com/path", "example.com:443", "user@example.com",
        "example.com?x", "example.com#x", "exa mple.com", "example.com\n", "ex_ample.com", "-a.example.com",
        "a-.example.com", "a..example.com", ".example.com", "example.com..", "bücher.example", "1.2.3.4", "127.0.0.1",
        "2130706433", "[::1]", "::1", "example.123", "*.1.2",
        String(repeating: "a", count: 64) + ".com",
        String(repeating: "a.", count: 130) + "com",
    ])
    func malformedOrDangerousPatternsAreRefused(_ text: String) {
        #expect(Self.parse(text) == nil, "\(text.debugDescription) should be refused")
    }

    @Test func parseFailuresExplainThemselves() {
        #expect(throws: LeoPluginHostPatternError.self) { try LeoPluginHostPattern.parse("*.com") }
        do { _ = try LeoPluginHostPattern.parse("*") } catch let e as LeoPluginHostPatternError {
            #expect(!e.reason.isEmpty)
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func exactMatchingIsCaseInsensitiveAndIgnoresOneTrailingDot() throws {
        let pattern = try LeoPluginHostPattern.parse("api.github.com")
        #expect(pattern.matches(host: "api.github.com"))
        #expect(pattern.matches(host: "API.GITHUB.COM"))
        #expect(pattern.matches(host: "api.github.com."))
        #expect(!pattern.matches(host: "api.github.com.."))
        #expect(!pattern.matches(host: "x.api.github.com"))
        #expect(!pattern.matches(host: "github.com"))
        #expect(!pattern.matches(host: "api.github.com.evil.test"))
        #expect(!pattern.matches(host: ""))
    }

    @Test func wildcardMatchesStrictSubdomainsAtAnyDepthButNotTheApexOrLookalikes() throws {
        let pattern = try LeoPluginHostPattern.parse("*.example.com")
        #expect(pattern.matches(host: "a.example.com"))
        #expect(pattern.matches(host: "A.Example.COM"))
        #expect(pattern.matches(host: "a.example.com."))
        #expect(pattern.matches(host: "a.b.example.com"))
        #expect(!pattern.matches(host: "example.com"))
        #expect(!pattern.matches(host: "example.com."))
        #expect(!pattern.matches(host: ".example.com"))
        #expect(!pattern.matches(host: "evilexample.com"))
        #expect(!pattern.matches(host: "example.com.evil.test"))
        #expect(!pattern.matches(host: "a.example.com.evil.test"))
        #expect(!pattern.matches(host: "a..example.com"))
    }

    @Test func coverageFollowsWhatTheOldPatternAlreadyAllowed() throws {
        let wild = try LeoPluginHostPattern.parse("*.example.com")
        let deeper = try LeoPluginHostPattern.parse("*.b.example.com")
        let exact = try LeoPluginHostPattern.parse("a.example.com")
        let apex = try LeoPluginHostPattern.parse("example.com")
        #expect(wild.covers(exact))
        #expect(wild.covers(deeper))
        #expect(wild.covers(wild))
        #expect(!wild.covers(apex))
        #expect(!deeper.covers(wild))
        #expect(!exact.covers(wild))
        #expect(exact.covers(exact))
        #expect(!exact.covers(apex))
    }
}

struct LeoPluginPermissionEngineTests {
    static func engine(
        network: [String] = [], secrets: Bool = false, agents: [LeoPluginAgentVerb] = []
    ) -> LeoPluginPermissionEngine {
        LeoPluginPermissionEngine(permissions: LeoPluginPermissions(network: network, secrets: secrets, agents: agents))
    }

    static func allowed(_ engine: LeoPluginPermissionEngine, _ url: String, hop: Int = 0) -> Bool {
        guard let parsed = URL(string: url) else { return false }
        return engine.check(url: parsed, hop: hop).isAllowed
    }

    // MARK: - Network

    @Test func exactAndWildcardHostsAreAllowedOverHTTPSOnAnyPort() {
        let engine = Self.engine(network: ["api.github.com", "*.githubusercontent.com"])
        #expect(Self.allowed(engine, "https://api.github.com/user"))
        #expect(Self.allowed(engine, "https://api.github.com:8443/user?q=1#f"))
        #expect(Self.allowed(engine, "HTTPS://API.GITHUB.COM/user"))
        #expect(Self.allowed(engine, "https://api.github.com./user"))
        #expect(Self.allowed(engine, "https://raw.githubusercontent.com/x"))
        #expect(Self.allowed(engine, "https://a.b.githubusercontent.com/x"))
    }

    @Test func theWildcardApexAndLookalikesAreDenied() {
        let engine = Self.engine(network: ["*.github.com"])
        #expect(!Self.allowed(engine, "https://github.com/"))
        #expect(!Self.allowed(engine, "https://evilgithub.com/"))
        #expect(!Self.allowed(engine, "https://github.com.evil.test/"))
        #expect(!Self.allowed(engine, "https://api.github.com.evil.test/"))
    }

    @Test(arguments: ["http://api.github.com/", "ftp://api.github.com/", "file:///etc/passwd", "wss://api.github.com/", "data:text/plain,hi", "javascript:alert(1)"])
    func nonHTTPSSchemesAreDenied(_ url: String) {
        #expect(!Self.allowed(Self.engine(network: ["api.github.com"]), url))
    }

    @Test(arguments: [
        "https://user@api.github.com/", "https://user:pw@api.github.com/", "https://api.github.com@evil.test/",
        "https://api.github.com:pw@evil.test/", "https://:@api.github.com/",
    ])
    func urlsWithUserinfoAreDenied(_ url: String) {
        #expect(!Self.allowed(Self.engine(network: ["api.github.com", "evil.test"]), url))
    }

    @Test(arguments: [
        "https://evil.test#@api.github.com/", "https://evil.test?@api.github.com/", "https://evil.test/@api.github.com",
        "https://api.github.com%2eevil.test/", "https://api%2egithub.com/", "https://api.github.com%00.evil.test/",
    ])
    func parserConfusionTricksDoNotReachTheAllowlist(_ url: String) {
        #expect(!Self.allowed(Self.engine(network: ["api.github.com"]), url))
    }

    @Test func urlsWithNoHostOrAnIPLiteralHostAreDenied() {
        let engine = Self.engine(network: ["api.github.com"])
        #expect(!Self.allowed(engine, "https:///path"))
        #expect(!Self.allowed(engine, "https://127.0.0.1/"))
        #expect(!Self.allowed(engine, "https://[::1]/"))
        #expect(!Self.allowed(engine, "https://2130706433/"))
    }

    @Test func aBackslashInTheURLIsDenied() throws {
        let url = try #require(URL(string: "https://api.github.com/a%5Cb"))
        #expect(Self.engine(network: ["api.github.com"]).check(url: url, hop: 0).isAllowed)
        // A raw backslash can't survive URL(string:) on every Foundation, so
        // build the URL from components to prove the engine refuses it anyway.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com\\@evil.test"
        if let weird = components.url {
            #expect(!Self.engine(network: ["api.github.com", "evil.test"]).check(url: weird, hop: 0).isAllowed)
        }
    }

    @Test func aPluginWithNoNetworkPermissionCannotFetchAnything() {
        #expect(!Self.allowed(Self.engine(), "https://api.github.com/"))
    }

    @Test func anInvalidStoredPatternAllowsNothing() {
        let engine = Self.engine(network: ["*", "*.com", "https://api.github.com"])
        #expect(!Self.allowed(engine, "https://api.github.com/"))
        #expect(!Self.allowed(engine, "https://example.com/"))
    }

    @Test func everyRedirectHopIsCheckedAndAHopLeavingTheAllowlistIsDenied() throws {
        let engine = Self.engine(network: ["api.github.com", "*.githubusercontent.com"])
        let chain = [
            "https://api.github.com/login",
            "https://api.github.com/login/device",
            "https://evil.test/steal",
            "https://api.github.com/back",
        ]
        let decisions = chain.enumerated().map { hop, url in
            engine.check(url: URL(string: url)!, hop: hop)
        }
        #expect(decisions.map(\.isAllowed) == [true, true, false, true])
        guard case .denied(let reason) = decisions[2] else {
            Issue.record("expected denial")
            return
        }
        #expect(reason.contains("evil.test"))
        #expect(reason.contains("redirect"))
    }

    @Test func anHTTPSToHTTPDowngradeOnARedirectHopIsDenied() {
        let engine = Self.engine(network: ["api.github.com"])
        #expect(!Self.allowed(engine, "http://api.github.com/x", hop: 1))
    }

    @Test func tooManyRedirectHopsAreDenied() {
        let engine = Self.engine(network: ["api.github.com"])
        #expect(Self.allowed(engine, "https://api.github.com/", hop: LeoPluginPermissionEngine.maxRedirectHops))
        #expect(!Self.allowed(engine, "https://api.github.com/", hop: LeoPluginPermissionEngine.maxRedirectHops + 1))
        #expect(!Self.allowed(engine, "https://api.github.com/", hop: -1))
    }

    // MARK: - Secrets and agents

    @Test func secretsFollowThePermissionFlag() {
        #expect(Self.engine(secrets: true).checkSecrets().isAllowed)
        guard case .denied(let reason) = Self.engine(secrets: false).checkSecrets() else {
            Issue.record("expected denial")
            return
        }
        #expect(reason.contains("secrets"))
    }

    @Test func eachAgentVerbIsGatedIndependently() {
        let readOnly = Self.engine(agents: [.read])
        #expect(readOnly.check(agent: .read).isAllowed)
        #expect(!readOnly.check(agent: .send).isAllowed)
        #expect(!readOnly.check(agent: .spawn).isAllowed)
        let sendOnly = Self.engine(agents: [.send])
        #expect(!sendOnly.check(agent: .read).isAllowed)
        #expect(sendOnly.check(agent: .send).isAllowed)
        #expect(Self.engine(agents: [.spawn]).check(agent: .spawn).isAllowed)
        #expect(!Self.engine().check(agent: .read).isAllowed)
    }

    @Test func aDeniedAgentVerbNamesTheMissingPermission() {
        guard case .denied(let reason) = Self.engine().check(agent: .spawn) else {
            Issue.record("expected denial")
            return
        }
        #expect(reason.contains("agents:spawn"))
    }
}

struct LeoPluginPermissionDiffTests {
    static func perms(
        _ network: [String] = [], secrets: Bool = false, agents: [LeoPluginAgentVerb] = []
    ) -> LeoPluginPermissions {
        LeoPluginPermissions(network: network, secrets: secrets, agents: agents)
    }

    @Test func identicalPermissionsHaveNoIncrease() {
        let p = Self.perms(["api.github.com"], secrets: true, agents: [.read])
        let diff = LeoPluginPermissionDiff(old: p, new: p)
        #expect(diff.isEmpty)
        #expect(diff == LeoPluginPermissionDiff(old: p, new: p))
    }

    @Test func listsAddedHostsSecretsAndAgentVerbs() {
        let diff = LeoPluginPermissionDiff(
            old: Self.perms(["api.github.com"], agents: [.read]),
            new: Self.perms(["api.github.com", "*.Example.com", "other.test"], secrets: true, agents: [.read, .spawn, .send])
        )
        #expect(diff.addedHosts == ["*.example.com", "other.test"])
        #expect(diff.secretsEnabled)
        #expect(diff.addedAgentVerbs == [.send, .spawn])
        #expect(!diff.isEmpty)
    }

    @Test func reductionsAreNotReportedAsIncreases() {
        let diff = LeoPluginPermissionDiff(
            old: Self.perms(["a.test", "b.test"], secrets: true, agents: [.read, .send, .spawn]),
            new: Self.perms(["a.test"], secrets: false, agents: [.read])
        )
        #expect(diff.isEmpty)
    }

    @Test func aHostAlreadyCoveredByAnOldWildcardIsNotAnIncrease() {
        let diff = LeoPluginPermissionDiff(old: Self.perms(["*.example.com"]), new: Self.perms(["api.example.com", "*.v2.example.com"]))
        #expect(diff.isEmpty)
    }

    @Test func broadeningAnExactHostToAWildcardOrAddingTheApexIsAnIncrease() {
        let widened = LeoPluginPermissionDiff(old: Self.perms(["api.example.com"]), new: Self.perms(["*.example.com"]))
        #expect(widened.addedHosts == ["*.example.com"])
        let apex = LeoPluginPermissionDiff(old: Self.perms(["*.example.com"]), new: Self.perms(["example.com"]))
        #expect(apex.addedHosts == ["example.com"])
    }

    @Test func hostCaseAndTrailingDotDoNotCreateFalseIncreases() {
        let diff = LeoPluginPermissionDiff(old: Self.perms(["API.example.com."]), new: Self.perms(["api.EXAMPLE.com"]))
        #expect(diff.isEmpty)
    }

    @Test func anUnparsableNewHostFailsClosedAsAnAddition() {
        let diff = LeoPluginPermissionDiff(old: Self.perms(["a.test"]), new: Self.perms(["a.test", "*"]))
        #expect(diff.addedHosts == ["*"])
    }

    @Test func installingFromNothingListsEverything() {
        let diff = LeoPluginPermissionDiff(old: .none, new: Self.perms(["a.test"], secrets: true, agents: [.read]))
        #expect(diff.addedHosts == ["a.test"])
        #expect(diff.secretsEnabled)
        #expect(diff.addedAgentVerbs == [.read])
    }
}
