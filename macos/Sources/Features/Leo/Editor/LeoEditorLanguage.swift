import Foundation

/// The languages the built-in highlighter knows, picked from a file's
/// extension (or, for extensionless dotfiles, its name).
enum LeoEditorLanguage: String, CaseIterable, Sendable {
    case swift, zig, go, python, javascript, typescript, json, markdown, shell, yaml, toml, plainText

    init(path: String) {
        let name = (path as NSString).lastPathComponent
        let fileExtension = (name as NSString).pathExtension.lowercased()
        self = Self.byExtension[fileExtension] ?? Self.byName[name] ?? .plainText
    }

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .zig: "Zig"
        case .go: "Go"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .shell: "Shell"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .plainText: "Plain Text"
        }
    }

    private static let byExtension: [String: LeoEditorLanguage] = [
        "swift": .swift,
        "zig": .zig, "zon": .zig,
        "go": .go,
        "py": .python, "pyi": .python, "pyw": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "json": .json, "jsonc": .json,
        "md": .markdown, "markdown": .markdown,
        "sh": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
    ]

    /// Shell dotfiles have no extension (`pathExtension` of `.zshrc` is empty).
    private static let byName: [String: LeoEditorLanguage] = [
        ".bashrc": .shell, ".bash_profile": .shell, ".bash_logout": .shell, ".profile": .shell,
        ".zshrc": .shell, ".zshenv": .shell, ".zprofile": .shell, ".zlogin": .shell, ".zlogout": .shell,
        ".envrc": .shell,
    ]
}
