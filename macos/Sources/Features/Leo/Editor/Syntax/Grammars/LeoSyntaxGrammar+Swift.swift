extension LeoSyntaxGrammar {
    static let swift = LeoSyntaxGrammar(rules: [
        .lineComment("//"),
        .blockComment,
        LeoSyntaxRule(.string, #""""[\s\S]*?(?:"""|\z)"#),
        .doubleQuoted,
        .atName,
        .number,
        .words(.literal, ["true", "false", "nil"]),
        .words(.keyword, [
            "actor", "any", "as", "associatedtype", "async", "await", "borrowing", "break", "case", "catch",
            "class", "consuming", "continue", "convenience", "default", "defer", "deinit", "didSet", "do",
            "dynamic", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "get",
            "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated", "lazy",
            "let", "macro", "mutating", "nonisolated", "nonmutating", "open", "operator", "override", "package",
            "precedencegroup", "private", "protocol", "public", "repeat", "required", "rethrows", "return",
            "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
            "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet",
        ]),
        .capitalizedType,
    ])
}
