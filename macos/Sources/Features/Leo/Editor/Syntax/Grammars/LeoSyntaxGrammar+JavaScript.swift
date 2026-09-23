/// JavaScript, and TypeScript as JavaScript plus its type keywords.
extension LeoSyntaxGrammar {
    static let javaScript = LeoSyntaxGrammar(rules: javaScriptRules(typeScript: false))
    static let typeScript = LeoSyntaxGrammar(rules: javaScriptRules(typeScript: true))

    private static let javaScriptKeywords = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "get", "if", "import",
        "in", "instanceof", "let", "new", "of", "return", "set", "static", "super", "switch", "this", "throw",
        "try", "typeof", "var", "void", "while", "with", "yield",
    ]

    private static let typeScriptKeywords = [
        "abstract", "declare", "enum", "implements", "infer", "interface", "is", "keyof", "namespace", "private",
        "protected", "public", "readonly", "satisfies", "type",
    ]

    private static func javaScriptRules(typeScript: Bool) -> [LeoSyntaxRule] {
        var rules: [LeoSyntaxRule] = [
            .lineComment("//"),
            .blockComment,
            // Template literals span lines.
            LeoSyntaxRule(.string, LeoSyntaxRule.quoted("`", crossingLines: true)),
            .doubleQuoted,
            .singleQuoted,
            .atName,
            LeoSyntaxRule(
                .number,
                #"\b(?:0[xX][0-9a-fA-F_]+n?|0[bB][01_]+n?|0[oO][0-7_]+n?|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?n?)\b"#
            ),
            .words(.literal, ["true", "false", "null", "undefined", "NaN", "Infinity"]),
        ]
        if typeScript {
            rules.append(.words(.type, ["any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown", "void"]))
        }
        rules.append(.words(.keyword, javaScriptKeywords + (typeScript ? typeScriptKeywords : [])))
        rules.append(.capitalizedType)
        return rules
    }
}
