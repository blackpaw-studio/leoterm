import Foundation

/// The resolved local observability endpoint: the daemon's web API, reachable
/// only on the machine leo runs on (bound to `127.0.0.1` regardless of the
/// `bind:` setting, which controls the *remote* listener).
struct LeoObserveConfig: Equatable, Sendable {
    let baseURL: URL
    let token: String
}

/// Whether `~/.leo/leo.yaml`'s `web:` block exposes the observability API,
/// and on which port.
enum LeoWebConfig: Equatable, Sendable {
    case disabled
    case enabled(port: Int)
}

/// Pure parsing of `leo.yaml`'s `web:` block and the API token file.
/// Deliberately dependency-free (no YAML library): the daemon's config file
/// is simple enough for a line-based scan, and pulling in a YAML parser for
/// two keys isn't worth the dependency surface.
enum LeoObserveConfigParsing {
    static let defaultPort = 8370

    /// Parse the top-level `web:` mapping out of `leo.yaml`'s raw contents.
    /// - A missing `web:` block is treated as enabled with the default port
    ///   (the daemon itself defaults this way).
    /// - `enabled: false` anywhere in the block disables the endpoint,
    ///   regardless of any `port:` value present.
    /// - An unparsable or missing `port:` falls back to `defaultPort`.
    static func parseWebConfig(yamlContent: String) -> LeoWebConfig {
        guard let block = extractWebBlock(from: yamlContent) else {
            return .enabled(port: defaultPort)
        }
        if firstValue(forKey: "enabled", in: block) == "false" {
            return .disabled
        }
        if let portValue = firstValue(forKey: "port", in: block), let port = Int(portValue) {
            return .enabled(port: port)
        }
        return .enabled(port: defaultPort)
    }

    /// Trim the API token file's contents. Whitespace/newlines are stripped;
    /// an empty (or whitespace-only) file is treated as "no token".
    static func parseToken(fileContent: String) -> String? {
        let trimmed = fileContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extract the lines belonging to a top-level `web:` mapping (i.e. every
    /// line up to, but not including, the next zero-indented key, or EOF).
    /// Tolerates any indentation width for the block's own keys.
    private static func extractWebBlock(from content: String) -> [String]? {
        let lines = content.components(separatedBy: .newlines)
        guard let startIndex = lines.firstIndex(where: { line in
            leadingWhitespaceCount(line) == 0 && line.trimmingCharacters(in: .whitespaces) == "web:"
        }) else {
            return nil
        }

        var blockLines: [String] = []
        for line in lines[(startIndex + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                continue
            }
            if leadingWhitespaceCount(line) == 0 {
                break
            }
            blockLines.append(line)
        }
        return blockLines
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).count
    }

    /// Find `key: value` within a block's lines, matched only at the block's
    /// own key indentation (the depth of the first line in `lines`) — a
    /// `key:` inside a nested sub-mapping (e.g. `web.cors.port`) sits deeper
    /// and must not shadow the block's own key. Strips inline `#` comments
    /// and surrounding double quotes.
    private static func firstValue(forKey key: String, in lines: [String]) -> String? {
        guard let ownDepth = lines.first.map(leadingWhitespaceCount) else { return nil }
        let prefix = "\(key):"
        for line in lines {
            guard leadingWhitespaceCount(line) == ownDepth else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            var value = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if let hashIndex = value.firstIndex(of: "#") {
                value = String(value[value.startIndex..<hashIndex]).trimmingCharacters(in: .whitespaces)
            }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}

/// Thin, non-pure loader: reads `leo.yaml` and the API token file from disk
/// and combines them into a resolved `LeoObserveConfig`. Paths are injected
/// (defaulting to the real locations) so this stays testable without
/// touching `~`.
enum LeoObserveConfigLoader {
    static func load(
        leoYamlPath: String = NSString(string: "~/.leo/leo.yaml").expandingTildeInPath,
        tokenPath: String = NSString(string: "~/.leo/state/api.token").expandingTildeInPath
    ) -> LeoObserveConfig? {
        guard let yamlContent = try? String(contentsOfFile: leoYamlPath, encoding: .utf8),
              case .enabled(let port) = LeoObserveConfigParsing.parseWebConfig(yamlContent: yamlContent) else {
            return nil
        }
        guard let tokenContent = try? String(contentsOfFile: tokenPath, encoding: .utf8),
              let token = LeoObserveConfigParsing.parseToken(fileContent: tokenContent) else {
            return nil
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            return nil
        }
        return LeoObserveConfig(baseURL: url, token: token)
    }
}
