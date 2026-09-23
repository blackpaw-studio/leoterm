extension LeoSyntaxGrammar {
    /// String prefixes (`r`, `b`, `f`, `rb`, …) belong to the string.
    private static let pythonPrefix = #"(?:\b[rRbBuUfF]{1,2})?"#

    static let python = LeoSyntaxGrammar(rules: [
        .lineComment("#"),
        LeoSyntaxRule(.string, pythonPrefix + #""""[\s\S]*?(?:"""|\z)"#),
        LeoSyntaxRule(.string, pythonPrefix + #"'''[\s\S]*?(?:'''|\z)"#),
        LeoSyntaxRule(.string, pythonPrefix + LeoSyntaxRule.quoted("\"")),
        LeoSyntaxRule(.string, pythonPrefix + LeoSyntaxRule.quoted("'")),
        // Decorators.
        LeoSyntaxRule(.attribute, #"@[A-Za-z_][A-Za-z0-9_.]*"#),
        .number,
        .words(.literal, ["True", "False", "None"]),
        .words(.keyword, [
            "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif",
            "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match",
            "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield",
        ]),
        .capitalizedType,
    ])
}
