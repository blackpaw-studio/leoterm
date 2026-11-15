import Foundation

/// One question of a `questions` input (leo `docs/configuration/chat.md`):
/// `{id, header, question, multi, allow_text, options}`. Answers are keyed by
/// `id` (`q1..qN`). Each option's value equals its label.
public struct LeoChatQuestion: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    /// The short chip label above the question; empty when the agent gave none.
    public let header: String
    public let question: String
    /// Whether several options may be chosen.
    public let multi: Bool
    public let allowsText: Bool
    public let options: [LeoChatOption]

    public init(id: String, header: String = "", question: String, multi: Bool = false, allowsText: Bool = true, options: [LeoChatOption]) {
        self.id = id
        self.header = header
        self.question = question
        self.multi = multi
        self.allowsText = allowsText
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case id, header, question, multi, options
        case allowsText = "allow_text"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            header: (try? container.decodeIfPresent(String.self, forKey: .header)) ?? "",
            question: (try? container.decodeIfPresent(String.self, forKey: .question)) ?? "",
            multi: (try? container.decodeIfPresent(Bool.self, forKey: .multi)) ?? false,
            allowsText: (try? container.decodeIfPresent(Bool.self, forKey: .allowsText)) ?? false,
            options: try container.decode([LeoChatOption].self, forKey: .options)
        )
    }
}
