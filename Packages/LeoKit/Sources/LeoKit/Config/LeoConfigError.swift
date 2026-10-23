import Foundation

/// One field-level validation message from a 422 (`field` is the schema key,
/// `harness_options.<key>`, `permissions.<key>` and so on; `""` is form-level).
public struct LeoConfigFieldError: Decodable, Equatable, Sendable {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    enum CodingKeys: String, CodingKey { case field, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            field: try container.decodeIfPresent(String.self, forKey: .field) ?? "",
            message: try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        )
    }
}

/// The config API's own failures. Anything else comes back as a
/// `LeoDaemonError`.
public enum LeoConfigError: Error, Equatable, Sendable {
    /// 409: the `If-Match` revision is stale; nothing was written.
    case conflict(currentRevision: String)
    /// 422: the daemon rejected the values.
    case invalid([LeoConfigFieldError])
    /// 428: a write arrived without `If-Match`.
    case revisionRequired
    /// The daemon has no config API (404 on the schema route).
    case unsupported
}

extension LeoConfigError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .conflict: "The configuration changed on the machine since you opened it."
        case .invalid(let errors): errors.first?.message ?? "The machine rejected these values."
        case .revisionRequired: "The write did not say which configuration it was based on."
        case .unsupported: "This machine's leo does not support editing settings from the app."
        }
    }
}
