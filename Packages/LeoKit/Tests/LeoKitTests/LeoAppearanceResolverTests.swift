import Foundation
import Testing

@testable import LeoKit

/// The Settings preview's resolver runs the daemon's own vectors
/// (`appearance-vectors.json`, byte-identical to leo
/// `internal/agent/testdata`), so the two can't drift apart.
struct LeoAppearanceResolverTests {
    struct Vector: Decodable, CustomTestStringConvertible, Sendable {
        struct Agent: Decodable, Sendable {
            let name: String
            let template: String
            let harness: String
            let environments: [String]
        }

        struct Manual: Decodable, Sendable {
            let emoji: String?
            let color: String?
        }

        struct Expected: Decodable, Sendable {
            let appearance: LeoAgentAppearance?
            init(from decoder: any Decoder) throws {
                struct Wrapper: Decodable {
                    let appearance: LeoAgentAppearance?
                    init(from decoder: any Decoder) throws { appearance = LeoAppearanceWire.agent(from: decoder) }
                }
                // Reuse the wire decoder: re-wrap the object under the key.
                let object = try decoder.singleValueContainer().decode(LeoConfigValue.self)
                let data = try JSONEncoder().encode(LeoConfigValue.object(["appearance": object]))
                appearance = try JSONDecoder().decode(Wrapper.self, from: data).appearance
            }
        }

        let name: String
        let agent: Agent
        let manual: Manual?
        let rules: [LeoAppearanceRule]
        let expected: Expected?

        var testDescription: String { name }
    }

    static let vectors: [Vector] = {
        struct File: Decodable { let cases: [Vector] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/appearance-vectors.json")
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.cases
    }()

    @Test func vectorsLoad() {
        #expect(Self.vectors.count >= 29)
    }

    @Test(arguments: vectors)
    func resolvesLikeTheDaemon(_ vector: Vector) {
        let facts = LeoAppearanceFacts(
            name: vector.agent.name, environments: vector.agent.environments,
            template: vector.agent.template, harness: vector.agent.harness
        )
        let manual = vector.manual.map { LeoAppearanceManual(emoji: $0.emoji, color: $0.color.flatMap(LeoAppearanceColor.init(rawValue:))) }
        let resolved = LeoAppearanceResolver.resolve(rules: vector.rules, facts: facts, manual: manual)
        #expect(resolved == vector.expected?.appearance)
    }

    @Test func problemsMatchTheDaemonsReasons() throws {
        let document = try LeoDaemonEnvelope<LeoAppearanceRulesDocument>.decode(rulesBody()).value()
        #expect(document.revision.hasPrefix("sha256:"))
        #expect(document.rules.count == 3)
        #expect(document.rules[1] == LeoAppearanceRule(field: "name", op: "glob", value: "alfred-*", color: "pink", emoji: "🎩"))
        #expect(document.errors == [LeoAppearanceRuleProblem(index: 2, reason: document.rules[2].problem ?? "")])
        #expect(document.rules[0].problem == nil)
    }

    @Test func problemOrderFollowsTheDaemon() {
        let palette = "red, orange, yellow, green, teal, blue, indigo, purple, pink, gray"
        let cases: [(LeoAppearanceRule, String?)] = [
            (.init(field: "machine", op: "is", value: "x", color: "red"), #"field "machine" must be one of name, environments, template, harness"#),
            (.init(field: "name", op: "matches", value: "x", color: "red"), #"op "matches" must be one of is, contains, starts_with, glob"#),
            (.init(field: "name", op: "is", value: "", color: "red"), "value is required"),
            (.init(field: "name", op: "glob", value: #"a\b"#, color: "red"), #"glob "a\\b" may only use the * and ? wildcards"#),
            (.init(field: "name", op: "is", value: "x"), "rule must set a color, an emoji, or both"),
            (.init(field: "name", op: "is", value: "x", color: "magenta"), #"color "magenta" is not in the palette (\#(palette))"#),
            (.init(field: "name", op: "is", value: "x", emoji: "ab"), #"emoji "ab" must be a single emoji (one grapheme cluster of at most 64 bytes)"#),
            (.init(field: "environments", op: "starts_with", value: "prod", color: "red", emoji: "🔥"), nil),
        ]
        for (rule, reason) in cases {
            #expect(rule.problem == reason, "\(rule)")
        }
    }

    @Test func encodesOnlyTheSetValues() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rule = LeoAppearanceRule(field: "name", op: "is", value: "a", color: "red")
        #expect(String(bytes: try encoder.encode(rule), encoding: .utf8) == #"{"color":"red","when":{"field":"name","op":"is","value":"a"}}"#)
    }

    @Test func summaryReadsAsASentence() {
        #expect(LeoAppearanceRule(field: "environments", op: "contains", value: "homelab", color: "teal").summary == "environments contains homelab")
        #expect(LeoAppearanceRule(field: "name", op: "starts_with", value: "alfred", color: "teal").summary == "name starts with alfred")
        #expect(LeoAppearanceRule(field: "name", op: "glob", value: "alfred-*", color: "teal").summary == "name matches alfred-*")
        #expect(LeoAppearanceRule(field: "harness", op: "is", value: "codex", color: "teal").summary == "harness is codex")
        #expect(LeoAppearanceRule(field: "machine", op: "near", value: "x", color: "teal").summary == "machine near x")
    }

    @Test func matchesTellsWhichAgentsARuleCovers() {
        let rule = LeoAppearanceRule(field: "environments", op: "contains", value: "homelab", color: "teal")
        #expect(rule.matches(LeoAppearanceFacts(name: "a", environments: ["homelab"], template: "t", harness: "")))
        #expect(!rule.matches(LeoAppearanceFacts(name: "a", environments: ["homelab-2"], template: "t", harness: "")))
        // An invalid rule never matches.
        #expect(!LeoAppearanceRule(field: "name", op: "is", value: "a").matches(LeoAppearanceFacts(name: "a", environments: [], template: "", harness: "")))
    }

    private func rulesBody() throws -> Data {
        struct Golden: Decodable { let body: LeoConfigValue }
        let golden = try JSONDecoder().decode(Golden.self, from: try LeoAppearanceWireTests.fixture("appearance-rules"))
        return try JSONEncoder().encode(golden.body)
    }
}
