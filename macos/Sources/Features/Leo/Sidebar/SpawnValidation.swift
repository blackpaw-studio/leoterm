import Foundation

enum SpawnValidation {
    static func name(_ value: String, current: String? = nil) -> String? {
        guard !value.isEmpty else { return nil }
        guard !value.hasPrefix("-") else { return "Name cannot begin with -" }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else { return "Name may only contain letters, numbers, ., _, and -" }
        if value == current { return "Name is unchanged" }
        return nil
    }
    static func rename(_ value: String, current: String) -> String? {
        guard !value.isEmpty else { return "Name is required" }
        guard !value.contains(where: { $0.isWhitespace || $0 == "/" }) else { return "Name cannot contain whitespace or /" }
        return name(value, current: current)
    }
    static func spawn(template: String?, repo: String, name: String?, pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard let template, !template.isEmpty else { return "Template is required" }
        guard repo.isEmpty || pathExists(repo) else { return "Choose an existing repository" }
        return name.flatMap { Self.name($0) }
    }
}
