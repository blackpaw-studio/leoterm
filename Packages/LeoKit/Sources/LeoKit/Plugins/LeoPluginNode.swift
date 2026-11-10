import Foundation

/// Limits enforced when decoding a plugin component tree.
public enum LeoPluginNodeLimits {
    public static let maxDepth = 8
    public static let maxNodes = 2_000
    public static let maxAccessoryText = 8
    public static let maxHelp = 80
}

public enum LeoPluginAccessoryColor: String, Codable, Equatable, Sendable {
    case neutral, success, warning, failure, running
}

/// One v1 component. Wire form: `{"type":"List", ...}`.
public indirect enum LeoPluginNode: Equatable, Sendable {
    case list(List)
    case detail(Detail)
    case form(Form)
    case accessory(Accessory)
    case emptyState(EmptyState)
    case loading(Loading)
    case error(ErrorState)

    public struct List: Codable, Equatable, Sendable {
        public var sections: [Section]
        public init(sections: [Section]) { self.sections = sections }
    }

    public struct Section: Codable, Equatable, Sendable {
        public var id: String?
        public var title: String?
        public var items: [Item]
        public init(id: String? = nil, title: String? = nil, items: [Item]) {
            self.id = id; self.title = title; self.items = items
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        }

        private enum Keys: String, CodingKey { case id, title, items }
    }

    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var sfSymbol: String?
        public var accessories: [Accessory]
        public var actions: [LeoPluginAction]
        public init(
            id: String, title: String, subtitle: String? = nil, sfSymbol: String? = nil,
            accessories: [Accessory] = [], actions: [LeoPluginAction] = []
        ) {
            self.id = id; self.title = title; self.subtitle = subtitle; self.sfSymbol = sfSymbol
            self.accessories = accessories; self.actions = actions
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(String.self, forKey: .id)
            guard !id.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "item id must not be empty")
            }
            title = try c.decode(String.self, forKey: .title)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            sfSymbol = try c.decodeIfPresent(String.self, forKey: .sfSymbol)
            accessories = try c.decodeIfPresent([Accessory].self, forKey: .accessories) ?? []
            actions = try c.decodeIfPresent([LeoPluginAction].self, forKey: .actions) ?? []
        }

        private enum Keys: String, CodingKey { case id, title, subtitle, sfSymbol, accessories, actions }
    }

    public struct Accessory: Codable, Equatable, Sendable {
        public var sfSymbol: String?
        public var text: String
        public var color: LeoPluginAccessoryColor
        public var help: String?
        public init(sfSymbol: String? = nil, text: String, color: LeoPluginAccessoryColor = .neutral, help: String? = nil) {
            self.sfSymbol = sfSymbol; self.text = text; self.color = color; self.help = help
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            sfSymbol = try c.decodeIfPresent(String.self, forKey: .sfSymbol)
            text = try c.decode(String.self, forKey: .text)
            color = try c.decodeIfPresent(LeoPluginAccessoryColor.self, forKey: .color) ?? .neutral
            help = try c.decodeIfPresent(String.self, forKey: .help)
            guard text.count <= LeoPluginNodeLimits.maxAccessoryText else {
                throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "accessory text over \(LeoPluginNodeLimits.maxAccessoryText) characters")
            }
            if let help, help.count > LeoPluginNodeLimits.maxHelp {
                throw DecodingError.dataCorruptedError(forKey: .help, in: c, debugDescription: "accessory help over \(LeoPluginNodeLimits.maxHelp) characters")
            }
        }

        private enum Keys: String, CodingKey { case sfSymbol, text, color, help }
    }

    public struct Detail: Codable, Equatable, Sendable {
        public var markdown: String
        public init(markdown: String) { self.markdown = markdown }
        /// Restricted-Markdown AST of `markdown`.
        public var blocks: [LeoPluginMarkdown.Block] { LeoPluginMarkdown.parse(markdown) }
    }

    public struct Form: Codable, Equatable, Sendable {
        public var id: String
        public var title: String?
        public var fields: [Field]
        public init(id: String, title: String? = nil, fields: [Field]) {
            self.id = id; self.title = title; self.fields = fields
        }
    }

    public struct Field: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Equatable, Sendable { case text, textArea, picker, checkbox, submit }
        public struct Option: Codable, Equatable, Sendable {
            public var value: String
            public var title: String
            public init(value: String, title: String) { self.value = value; self.title = title }
        }

        public var id: String
        public var type: Kind
        public var label: String?
        public var placeholder: String?
        public var value: String?
        public var checked: Bool?
        public var options: [Option]
        public var action: LeoPluginAction?

        public init(
            id: String, type: Kind, label: String? = nil, placeholder: String? = nil, value: String? = nil,
            checked: Bool? = nil, options: [Option] = [], action: LeoPluginAction? = nil
        ) {
            self.id = id; self.type = type; self.label = label; self.placeholder = placeholder
            self.value = value; self.checked = checked; self.options = options; self.action = action
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(String.self, forKey: .id)
            type = try c.decode(Kind.self, forKey: .type)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
            value = try c.decodeIfPresent(String.self, forKey: .value)
            checked = try c.decodeIfPresent(Bool.self, forKey: .checked)
            options = try c.decodeIfPresent([Option].self, forKey: .options) ?? []
            action = try c.decodeIfPresent(LeoPluginAction.self, forKey: .action)
            guard !id.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "field id must not be empty")
            }
            if type == .picker, options.isEmpty {
                throw DecodingError.dataCorruptedError(forKey: .options, in: c, debugDescription: "picker needs options")
            }
        }

        private enum Keys: String, CodingKey { case id, type, label, placeholder, value, checked, options, action }
    }

    public struct EmptyState: Codable, Equatable, Sendable {
        public var title: String
        public var message: String?
        public var sfSymbol: String?
        public var actions: [LeoPluginAction]
        public init(title: String, message: String? = nil, sfSymbol: String? = nil, actions: [LeoPluginAction] = []) {
            self.title = title; self.message = message; self.sfSymbol = sfSymbol; self.actions = actions
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            title = try c.decode(String.self, forKey: .title)
            message = try c.decodeIfPresent(String.self, forKey: .message)
            sfSymbol = try c.decodeIfPresent(String.self, forKey: .sfSymbol)
            actions = try c.decodeIfPresent([LeoPluginAction].self, forKey: .actions) ?? []
        }

        private enum Keys: String, CodingKey { case title, message, sfSymbol, actions }
    }

    public struct Loading: Codable, Equatable, Sendable {
        public var message: String?
        public init(message: String?) { self.message = message }
    }

    public struct ErrorState: Codable, Equatable, Sendable {
        public var message: String
        public var retry: LeoPluginAction
        public init(message: String, retry: LeoPluginAction) { self.message = message; self.retry = retry }
    }

    /// Nodes in this subtree, counting the component, list items, accessories and form fields.
    var nodeCount: Int {
        switch self {
        case .list(let l): 1 + l.sections.reduce(0) { $0 + $1.items.reduce(0) { $0 + 1 + $1.accessories.count } }
        case .form(let f): 1 + f.fields.count
        default: 1
        }
    }

    /// Longest root-to-leaf chain (component → item → accessory ...).
    var depth: Int {
        switch self {
        case .list(let l):
            let items = l.sections.flatMap(\.items)
            return 1 + (items.isEmpty ? 0 : 1 + (items.contains { !$0.accessories.isEmpty } ? 1 : 0))
        case .form(let f): return f.fields.isEmpty ? 1 : 2
        default: return 1
        }
    }
}

extension LeoPluginNode: Codable {
    private enum Keys: String, CodingKey { case type }
    private static let typeNames = "List, Detail, Form, Accessory, EmptyState, Loading, Error"

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .type)
        switch type {
        case "List": self = .list(try .init(from: decoder))
        case "Detail": self = .detail(try .init(from: decoder))
        case "Form": self = .form(try .init(from: decoder))
        case "Accessory": self = .accessory(try .init(from: decoder))
        case "EmptyState": self = .emptyState(try .init(from: decoder))
        case "Loading": self = .loading(try .init(from: decoder))
        case "Error": self = .error(try .init(from: decoder))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath + [Keys.type],
                debugDescription: "unknown component type \"\(type)\"; expected one of \(Self.typeNames)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .list(let v): try c.encode("List", forKey: .type); try v.encode(to: encoder)
        case .detail(let v): try c.encode("Detail", forKey: .type); try v.encode(to: encoder)
        case .form(let v): try c.encode("Form", forKey: .type); try v.encode(to: encoder)
        case .accessory(let v): try c.encode("Accessory", forKey: .type); try v.encode(to: encoder)
        case .emptyState(let v): try c.encode("EmptyState", forKey: .type); try v.encode(to: encoder)
        case .loading(let v): try c.encode("Loading", forKey: .type); try v.encode(to: encoder)
        case .error(let v): try c.encode("Error", forKey: .type); try v.encode(to: encoder)
        }
    }
}

/// A slot's content: one component or an ordered array drawn stacked. Validated on decode.
public struct LeoPluginSlotRoot: Codable, Equatable, Sendable {
    public let nodes: [LeoPluginNode]

    public init(nodes: [LeoPluginNode]) throws {
        try Self.validate(nodes)
        self.nodes = nodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let nodes: [LeoPluginNode]
        if let many = try? c.decode([LeoPluginNode].self) {
            nodes = many
        } else {
            nodes = [try c.decode(LeoPluginNode.self)]
        }
        do { try Self.validate(nodes) } catch let e as LeoPluginNodeError {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: e.description)
        }
        self.nodes = nodes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if nodes.count == 1 { try c.encode(nodes[0]) } else { try c.encode(nodes) }
    }

    private static func validate(_ nodes: [LeoPluginNode]) throws {
        let count = nodes.reduce(0) { $0 + $1.nodeCount }
        guard count <= LeoPluginNodeLimits.maxNodes else { throw LeoPluginNodeError.tooManyNodes(count) }
        let depth = (nodes.map(\.depth).max() ?? 0) + (nodes.count > 1 ? 1 : 0)
        guard depth <= LeoPluginNodeLimits.maxDepth else { throw LeoPluginNodeError.tooDeep(depth) }
        for case .list(let list) in nodes {
            var seen = Set<String>()
            for item in list.sections.flatMap(\.items) where !seen.insert(item.id).inserted {
                throw LeoPluginNodeError.duplicateItemID(item.id)
            }
        }
    }
}

public enum LeoPluginNodeError: Error, CustomStringConvertible, Equatable {
    case tooManyNodes(Int)
    case tooDeep(Int)
    case duplicateItemID(String)

    public var description: String {
        switch self {
        case .tooManyNodes(let n): "tree has \(n) nodes; limit is \(LeoPluginNodeLimits.maxNodes)"
        case .tooDeep(let d): "tree depth \(d) exceeds limit \(LeoPluginNodeLimits.maxDepth)"
        case .duplicateItemID(let id): "duplicate list item id \"\(id)\""
        }
    }
}
