import Foundation

/// What a sidebar row draws for the plugins' accessories: at most
/// `maxVisible` chips, then one "+N" for the rest. Pure, so the rules (symbol
/// allowlist, text clamp, order, overflow) are tested without a view.
///
/// Slots that haven't rendered, or failed, draw nothing: a row is too small
/// to carry a spinner or an error per plugin, and the plugin's own pane and
/// Settings show the failure.
public struct LeoPluginAccessoryLayout: Equatable, Sendable {
    public static let maxVisible = 2

    public struct Entry: Sendable {
        public let pluginID: String
        public let pluginName: String
        public let state: LeoPluginSlotState

        public init(pluginID: String, pluginName: String, state: LeoPluginSlotState) {
            self.pluginID = pluginID
            self.pluginName = pluginName
            self.state = state
        }
    }

    public struct Chip: Equatable, Sendable {
        public let pluginID: String
        /// Nil when the plugin asked for a symbol outside the allowlist.
        public let sfSymbol: String?
        public let text: String
        public let color: LeoPluginAccessoryColor
        /// Always names the plugin, so a tooltip can't pass as Leo's own.
        public let help: String
    }

    public struct Overflow: Equatable, Sendable {
        public let count: Int
        public let help: String
        public var label: String { "+\(count)" }
    }

    public let chips: [Chip]
    public let overflow: Overflow?
    private let all: [Chip]

    public init(entries: [Entry], maxVisible: Int = LeoPluginAccessoryLayout.maxVisible) {
        let all = entries
            .sorted { $0.pluginID < $1.pluginID }
            .compactMap(Self.chip(for:))
        self.init(all: all, visible: maxVisible)
    }

    private init(all: [Chip], visible: Int) {
        self.all = all
        chips = Array(all.prefix(max(0, visible)))
        let hidden = all.dropFirst(max(0, visible))
        overflow = hidden.isEmpty ? nil : Overflow(count: hidden.count, help: hidden.map(\.help).joined(separator: "\n"))
    }

    /// The same chips, with only the first `visibleCount` drawn and the rest
    /// behind "+N". A narrow row steps down through this (two chips, one,
    /// then just "+N") so the agent's name keeps its room.
    public func showing(_ visibleCount: Int) -> LeoPluginAccessoryLayout {
        LeoPluginAccessoryLayout(all: all, visible: min(visibleCount, Self.maxVisible))
    }

    /// How many chips the plugins have given this row, drawn or not.
    public var totalCount: Int { all.count }

    private static func chip(for entry: Entry) -> Chip? {
        guard case .tree(let root) = entry.state else { return nil }
        let accessory = root.nodes.lazy.compactMap { node -> LeoPluginNode.Accessory? in
            if case .accessory(let accessory) = node { accessory } else { nil }
        }.first
        guard let accessory else { return nil }
        let text = clamp(accessory.text)
        let symbol = accessory.sfSymbol.flatMap { LeoPluginSymbolAllowlist.isAllowed($0) ? $0 : nil }
        guard symbol != nil || !text.isEmpty else { return nil }
        return Chip(
            pluginID: entry.pluginID, sfSymbol: symbol, text: text, color: accessory.color,
            help: "\(entry.pluginName): \(accessory.help ?? text)")
    }

    private static func clamp(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(LeoPluginNodeLimits.maxAccessoryText))
    }
}
