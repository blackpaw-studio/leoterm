extension LeoSyntaxGrammar {
    static let go = LeoSyntaxGrammar(rules: [
        .lineComment("//"),
        .blockComment,
        // Raw strings span lines.
        LeoSyntaxRule(.string, #"`[^`]*`"#),
        .doubleQuoted,
        .singleQuoted,
        .number,
        .words(.literal, ["true", "false", "nil", "iota"]),
        .words(.type, [
            "any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32", "float64", "int",
            "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
        ]),
        .words(.keyword, [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
            "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var",
        ]),
        .capitalizedType,
    ])
}
