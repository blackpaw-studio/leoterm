extension LeoSyntaxGrammar {
    /// JSON, with JSONC comments (tsconfig.json and friends have them).
    static let json = LeoSyntaxGrammar(rules: [
        .lineComment("//"),
        .blockComment,
        LeoSyntaxRule(.key, #""(?:[^"\\\n]|\\.)*"(?=\s*:)"#),
        .doubleQuoted,
        LeoSyntaxRule(.number, #"-?\b(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\b"#),
        .words(.literal, ["true", "false", "null"]),
    ])
}
