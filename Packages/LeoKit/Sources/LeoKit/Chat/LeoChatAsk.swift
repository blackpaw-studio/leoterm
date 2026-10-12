import Foundation

/// How an `ask` (or a `permission` prompt) is answered:
/// `{type, options?, allow_text?, min?, max?, placeholder?}` (leo
/// `docs/configuration/chat.md`, "Ask inputs"). Decoding is strict and
/// mirrors the daemon's `validateInput`, so an input that decodes is one
/// the daemon could have stored.
public struct LeoChatInput: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Tapping a choice submits it.
        case buttons
        /// Select one choice, then submit.
        case radio
        /// Select `min`...`max` choices, then submit.
        case checkboxes
        /// One free-text field.
        case text
    }

    public static let maximumOptions = 12
    public static let maximumPlaceholderScalars = 200

    /// A permission prompt the daemon stored without an input (rows from
    /// before leo #268).
    public static let permission = LeoChatInput(
        unchecked: .buttons,
        options: [
            LeoChatOption(value: "allow", label: String(localized: "Allow")),
            LeoChatOption(value: "deny", label: String(localized: "Deny")),
        ]
    )

    public let kind: Kind
    /// Empty for `text`.
    public let options: [LeoChatOption]
    /// A choice type that also takes a free-text answer.
    public let allowsText: Bool
    /// The selection bounds: `0...options.count` unless `checkboxes` sets
    /// them; `0...0` for `text`.
    public let min: Int
    public let max: Int
    public let placeholder: String?

    /// A validated input; `max` nil means every option.
    public init(
        kind: Kind, options: [LeoChatOption] = [], allowsText: Bool = false, min: Int = 0, max: Int? = nil, placeholder: String? = nil
    ) throws(LeoChatInputError) {
        let placeholder = placeholder.flatMap { $0.isEmpty ? nil : $0 }
        if let placeholder, placeholder.unicodeScalars.count > Self.maximumPlaceholderScalars {
            throw .invalid("placeholder exceeds \(Self.maximumPlaceholderScalars) characters")
        }
        guard kind != .text else {
            guard options.isEmpty, !allowsText, min == 0, max == nil else { throw .invalid("a text input takes only a placeholder") }
            self.init(unchecked: kind, options: [], placeholder: placeholder)
            return
        }
        try Self.validate(options)
        if placeholder != nil, !allowsText { throw .invalid("placeholder needs a text input or allow_text") }
        guard kind == .checkboxes else {
            guard min == 0, max == nil else { throw .invalid("min and max apply to checkboxes only") }
            self.init(unchecked: kind, options: options, allowsText: allowsText, max: options.count, placeholder: placeholder)
            return
        }
        let upper = max ?? options.count
        guard min >= 0, upper >= 1, min <= upper, upper <= options.count else {
            throw .invalid("checkboxes need 0 <= min <= max <= \(options.count) options, and max at least 1")
        }
        self.init(unchecked: kind, options: options, allowsText: allowsText, min: min, max: upper, placeholder: placeholder)
    }

    private init(unchecked kind: Kind, options: [LeoChatOption], allowsText: Bool = false, min: Int = 0, max: Int? = nil, placeholder: String? = nil) {
        self.kind = kind
        self.options = options
        self.allowsText = allowsText
        self.min = min
        self.max = max ?? options.count
        self.placeholder = placeholder
    }

    private static func validate(_ options: [LeoChatOption]) throws(LeoChatInputError) {
        guard (1...maximumOptions).contains(options.count) else { throw .invalid("give 1 to \(maximumOptions) options") }
        var seen: Set<String> = []
        for option in options {
            guard !option.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(option.value).inserted else {
                throw .invalid("option values must be non-empty and distinct")
            }
        }
    }

    /// Whether the user picks one choice (`buttons`, `radio`) rather than several.
    public var isSingleChoice: Bool { kind == .buttons || kind == .radio }

    /// The label of `value`, else the value itself.
    public func label(of value: String) -> String {
        options.first { $0.value == value }?.label ?? value
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case type, options, min, max, placeholder
        case allowText = "allow_text"
    }

    /// Options on the wire are always `{value, label}` objects.
    private struct WireOption: Decodable {
        let value: String
        let label: String
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: type) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown input type \(type)")
        }
        let options = try container.decodeIfPresent([WireOption].self, forKey: .options) ?? []
        do {
            try self.init(
                kind: kind,
                options: options.map { LeoChatOption(value: $0.value, label: $0.label.isEmpty ? $0.value : $0.label) },
                allowsText: try container.decodeIfPresent(Bool.self, forKey: .allowText) ?? false,
                min: try container.decodeIfPresent(Int.self, forKey: .min) ?? 0,
                max: try container.decodeIfPresent(Int.self, forKey: .max),
                placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder)
            )
        } catch let error as LeoChatInputError {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.message))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        if !options.isEmpty { try container.encode(options, forKey: .options) }
        if allowsText { try container.encode(true, forKey: .allowText) }
        if kind == .checkboxes {
            if min != 0 { try container.encode(min, forKey: .min) }
            try container.encode(max, forKey: .max)
        }
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
    }
}

public enum LeoChatInputError: Error, Equatable, Sendable {
    case invalid(String)

    public var message: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// An answer: the chosen option values (in the order given) and any free
/// text. On the wire `{values, text}`; the daemon always sends `text`, and
/// `""` means none.
public struct LeoChatAnswer: Codable, Equatable, Hashable, Sendable {
    /// The daemon's cap on answer text, in Unicode scalars (Go runes).
    public static let maxTextScalars = 4000

    public let values: [String]
    public let text: String?

    public init(values: [String] = [], text: String? = nil) {
        self.values = values
        self.text = text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One chosen value, no text: a button tap.
    public static func choice(_ value: String) -> LeoChatAnswer {
        LeoChatAnswer(values: [value])
    }

    enum CodingKeys: String, CodingKey { case values, text }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            values: try container.decode([String].self, forKey: .values),
            text: try container.decodeIfPresent(String.self, forKey: .text)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
        try container.encodeIfPresent(text, forKey: .text)
    }
}

extension LeoChatMessage {
    /// The value a permission answer records when the agent's own terminal
    /// settled the prompt.
    public static let terminalAnswerValue = "terminal"

    /// This prompt with `answer` recorded, for when the daemon answered
    /// without returning the message.
    public func answered(_ answer: LeoChatAnswer) -> LeoChatMessage {
        LeoChatMessage(
            id: id, agent: agent, direction: direction, kind: kind, text: text, transcript: transcript, replyTo: replyTo, task: task,
            runID: runID, state: "answered", answer: answer, ts: ts, attachments: attachments, input: input
        )
    }

    /// A permission prompt answered in the agent's terminal, not in chat.
    public var isAnsweredInTerminal: Bool {
        kind == .permission && answer?.values == [Self.terminalAnswerValue]
    }

    /// The recorded answer as one line: the chosen labels in answer order
    /// (a value with no option shows as itself), then any text.
    public var answerSummary: String? {
        guard let answer else { return nil }
        let labels = answer.values.map { answerInput?.label(of: $0) ?? $0 }
        let parts = [labels.isEmpty ? nil : labels.joined(separator: ", "), answer.text].compactMap { $0 }
        return parts.isEmpty ? String(localized: "None") : parts.joined(separator: " — ")
    }

    /// Whether this `ask` follows up the agent's post just before it (the
    /// file or text it asks about), so the two read as one.
    public func continuesPost(after previous: LeoChatMessage?) -> Bool {
        guard kind == .ask, let previous, previous.direction == .outbound,
              [.text, .file, .task].contains(previous.kind) else { return false }
        return previous.agent == agent && previous.task == task && previous.runID == runID
    }
}
