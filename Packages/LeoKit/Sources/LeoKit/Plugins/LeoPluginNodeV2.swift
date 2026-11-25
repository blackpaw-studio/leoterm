import Foundation

/// How a decoder learns which plugin API a tree is written against. The app
/// sets `apiVersionKey` to the plugin's manifest `apiVersion` before decoding
/// a host frame; a decoder without it is treated as version 1, so the v2
/// components below are refused unless a caller opts in.
public enum LeoPluginNodeDecoding {
    // swiftlint:disable:next force_unwrapping
    public static let apiVersionKey = CodingUserInfoKey(rawValue: "leo.plugin.apiVersion")!
    /// The API version that added `Group` and the value-form `Meter`.
    public static let groupAPIVersion = 2

    static func apiVersion(of decoder: Decoder) -> Int {
        decoder.userInfo[apiVersionKey] as? Int ?? 1
    }

    static func requireGroupAPI(_ decoder: Decoder, type: String) throws {
        guard apiVersion(of: decoder) >= groupAPIVersion else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\(type) requires plugin API version \(groupAPIVersion)"))
        }
    }
}

/// The value-form `Meter`'s tone: a semantic tint, mapped by the app to a
/// system dynamic colour.
public enum LeoPluginMeterTone: String, Codable, Equatable, Sendable, CaseIterable {
    case neutral, success, warning, failure
}

extension LeoPluginNodeLimits {
    public static let maxMeterValueText = 16
    public static let maxMeterDetail = 80
    public static let maxGroupTitle = 80
    public static let maxGroupSubtitle = 200
    public static let maxGroupChildren = 16
}

extension LeoPluginNode {
    /// One labelled level from 0 to 1 (apiVersion 2). Wire form:
    /// `{"type":"Meter","label":…,"value":0.42,"valueText":"42%","detail":…,"tone":"success"}`.
    /// It shares the type name with the segments `Meter`; the `value` key picks this form.
    public struct ValueMeter: Codable, Equatable, Sendable {
        public var label: String
        /// Always within 0…1: out-of-range input is clamped at decode.
        public var value: Double
        public var valueText: String?
        public var detail: String?
        public var tone: LeoPluginMeterTone

        public init(label: String, value: Double, valueText: String? = nil, detail: String? = nil, tone: LeoPluginMeterTone = .neutral) {
            self.label = label
            self.value = value.isFinite ? Swift.min(Swift.max(value, 0), 1) : 0
            self.valueText = valueText
            self.detail = detail
            self.tone = tone
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            if c.contains(.segments) || c.contains(.max) {
                throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "Meter takes either value or segments, not both")
            }
            let raw = try c.decode(Double.self, forKey: .value)
            guard raw.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "Meter value must be finite")
            }
            self.init(
                label: try c.decode(String.self, forKey: .label),
                value: raw,
                valueText: try c.decodeIfPresent(String.self, forKey: .valueText),
                detail: try c.decodeIfPresent(String.self, forKey: .detail),
                tone: try c.decodeIfPresent(LeoPluginMeterTone.self, forKey: .tone) ?? .neutral)
            try checkLength(label, LeoPluginNodeLimits.maxMeterLabel, key: .label, in: c)
            try checkLength(valueText, LeoPluginNodeLimits.maxMeterValueText, key: .valueText, in: c)
            try checkLength(detail, LeoPluginNodeLimits.maxMeterDetail, key: .detail, in: c)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(label, forKey: .label)
            try c.encode(value, forKey: .value)
            try c.encodeIfPresent(valueText, forKey: .valueText)
            try c.encodeIfPresent(detail, forKey: .detail)
            try c.encode(tone, forKey: .tone)
        }

        enum Keys: String, CodingKey { case type, label, value, valueText, detail, tone, segments, max }
    }

    /// A titled block of meters and accessories (apiVersion 2), e.g. one account.
    public struct Group: Codable, Equatable, Sendable {
        /// What a Group may hold. Anything else is refused at decode.
        public enum Child: Codable, Equatable, Sendable {
            case meter(ValueMeter)
            case accessory(Accessory)

            public init(from decoder: Decoder) throws {
                switch try LeoPluginNode(from: decoder) {
                case .valueMeter(let meter): self = .meter(meter)
                case .accessory(let accessory): self = .accessory(accessory)
                default:
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: decoder.codingPath, debugDescription: "a Group child must be a value Meter or an Accessory"))
                }
            }

            public func encode(to encoder: Encoder) throws {
                switch self {
                case .meter(let meter): try LeoPluginNode.valueMeter(meter).encode(to: encoder)
                case .accessory(let accessory): try LeoPluginNode.accessory(accessory).encode(to: encoder)
                }
            }
        }

        /// How a Group lays out its meter children. `inline` puts them side by
        /// side on one line, each with its detail under its own bar.
        public enum MeterLayout: String, Codable, Equatable, Sendable {
            case stacked, inline
        }

        public var title: String
        public var subtitle: String?
        public var sfSymbol: String?
        public var accessory: Accessory?
        public var children: [Child]
        public var actions: [LeoPluginLabeledAction]
        public var meterLayout: MeterLayout

        public init(
            title: String, subtitle: String? = nil, sfSymbol: String? = nil, accessory: Accessory? = nil,
            children: [Child] = [], actions: [LeoPluginLabeledAction] = [], meterLayout: MeterLayout = .stacked
        ) {
            self.title = title; self.subtitle = subtitle; self.sfSymbol = sfSymbol; self.accessory = accessory
            self.children = children; self.actions = actions; self.meterLayout = meterLayout
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            title = try c.decode(String.self, forKey: .title)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            // Same rule as Accessory: a symbol outside the allowlist never reaches a renderer.
            sfSymbol = try c.decodeIfPresent(String.self, forKey: .sfSymbol).flatMap { LeoPluginSymbolAllowlist.isAllowed($0) ? $0 : nil }
            accessory = try c.decodeIfPresent(Accessory.self, forKey: .accessory)
            children = try c.decodeIfPresent([Child].self, forKey: .children) ?? []
            actions = try c.decodeIfPresent([LeoPluginLabeledAction].self, forKey: .actions) ?? []
            // A layout this host doesn't know (a newer plugin) draws stacked rather than refusing the tree.
            meterLayout = (try? c.decodeIfPresent(MeterLayout.self, forKey: .meterLayout)).flatMap { $0 } ?? .stacked
            try checkLength(title, LeoPluginNodeLimits.maxGroupTitle, key: .title, in: c)
            try checkLength(subtitle, LeoPluginNodeLimits.maxGroupSubtitle, key: .subtitle, in: c)
            guard children.count <= LeoPluginNodeLimits.maxGroupChildren else {
                throw DecodingError.dataCorruptedError(
                    forKey: .children, in: c, debugDescription: "Group has more than \(LeoPluginNodeLimits.maxGroupChildren) children")
            }
        }

        private enum Keys: String, CodingKey { case title, subtitle, sfSymbol, accessory, children, actions, meterLayout }
    }
}

private func checkLength<K: CodingKey>(_ text: String?, _ limit: Int, key: K, in c: KeyedDecodingContainer<K>) throws {
    guard let text, text.count > limit else { return }
    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "\(key.stringValue) over \(limit) characters")
}
