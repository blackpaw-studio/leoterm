extension LeoSyntaxGrammar {
    static let toml = LeoSyntaxGrammar(rules: [
        .lineComment("#"),
        LeoSyntaxRule(.string, #""""[\s\S]*?(?:"""|\z)"#),
        LeoSyntaxRule(.string, #"'''[\s\S]*?(?:'''|\z)"#),
        .doubleQuoted,
        LeoSyntaxRule(.string, #"'[^'\n]*'"#),
        // [table] and [[array of tables]] headers.
        LeoSyntaxRule(.heading, #"^[ \t]*\[\[?[^\]\n]*\]\]?"#),
        LeoSyntaxRule(.key, #"(?:^|(?<=^[ \t]{1,40})|(?<=[{,][ \t]{0,10}))[A-Za-z0-9_\-.]+(?=[ \t]*=)"#),
        // Dates and times.
        LeoSyntaxRule(
            .number,
            #"\b[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[T ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]+)?)?(?:Z|[+-][0-9]{2}:[0-9]{2})?)?"#
        ),
        LeoSyntaxRule(
            .number,
            #"[-+]?\b(?:0x[0-9a-fA-F_]+|0o[0-7_]+|0b[01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?|inf|nan)\b"#
        ),
        .words(.literal, ["true", "false"]),
    ])
}
