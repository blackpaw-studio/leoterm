import Foundation

/// Size caps for data a plugin host hands the app.
public enum LeoPluginFrameLimits {
    /// Largest host → app frame (one JSON request) accepted, in UTF-8 bytes.
    public static let maxFrameBytes = 1_048_576
    /// Largest Markdown source parsed, in UTF-8 bytes.
    public static let maxMarkdownBytes = 65_536
}

public enum LeoPluginFrameError: Error, Equatable, CustomStringConvertible, Sendable {
    case tooLarge(bytes: Int)

    public var description: String {
        switch self {
        case .tooLarge(let bytes): "frame is \(bytes) bytes; limit is \(LeoPluginFrameLimits.maxFrameBytes)"
        }
    }
}

public enum LeoPluginFrame {
    /// Decodes one host → app frame. The byte cap is checked before any parsing.
    public static func decodeRequest(_ json: String) throws -> LeoPluginHostRequest {
        let bytes = json.utf8.count
        guard bytes <= LeoPluginFrameLimits.maxFrameBytes else { throw LeoPluginFrameError.tooLarge(bytes: bytes) }
        return try JSONDecoder().decode(LeoPluginHostRequest.self, from: Data(json.utf8))
    }
}
