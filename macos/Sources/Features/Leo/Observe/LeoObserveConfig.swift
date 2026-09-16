import Foundation

struct LeoObserveConfig: Equatable, Sendable {
    let baseURL: URL
    let token: String
}

enum LeoObserveConfigLoader {
    static func load(
        yamlPath: String = NSString(string: "~/.leo/leo.yaml").expandingTildeInPath,
        tokenPath: String = NSString(string: "~/.leo/state/api.token").expandingTildeInPath
    ) -> LeoObserveConfig? {
        guard let yaml = try? String(contentsOfFile: yamlPath, encoding: .utf8),
              let web = parseWeb(yaml), web.enabled,
              let token = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let url = baseURL(bind: web.bind, port: web.port) else { return nil }
        return LeoObserveConfig(baseURL: url, token: token)
    }

    static func parseWeb(_ yaml: String) -> (enabled: Bool, port: Int, bind: String)? {
        let lines = yaml.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0 == "web:" }) else { return nil }
        var enabled = false
        var port = 8370
        var bind = "127.0.0.1"
        for line in lines[(start + 1)...] {
            guard line.first == " " || line.first == "\t" else { break }
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let key = fields[0]
            let value = fields[1].trimmingCharacters(in: .whitespaces).split(separator: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch key {
            case "enabled": enabled = value != "false"
            case "port": port = Int(value) ?? 8370
            case "bind": bind = value
            default: break
            }
        }
        return (enabled, port, bind)
    }

    static func baseURL(bind: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = bind.contains(":") ? "[\(bind)]" : bind
        components.port = port
        return components.url
    }
}
