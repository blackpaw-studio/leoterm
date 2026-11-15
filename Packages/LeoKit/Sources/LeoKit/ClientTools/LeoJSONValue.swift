import Foundation

/// Any JSON value, for the parts of the client-tools wire the app passes
/// through untouched: tool arguments, JSON Schemas and unrecognised content
/// blocks. Integers stay integers so a `timeout_s` or an `ms` argument
/// round-trips exactly.
public enum LeoJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([LeoJSONValue])
    case object([String: LeoJSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LeoJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LeoJSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value == value.rounded() && abs(value) < 9e15: Int(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: LeoJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
