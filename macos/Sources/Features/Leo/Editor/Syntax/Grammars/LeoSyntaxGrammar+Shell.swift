extension LeoSyntaxGrammar {
    static let shell = LeoSyntaxGrammar(rules: [
        // `#` starts a comment only at the start of a word.
        LeoSyntaxRule(.comment, #"#(?<![^\s;|&(]#)[^\n]*"#),
        LeoSyntaxRule(.string, #"'[^']*'"#),
        LeoSyntaxRule(.string, LeoSyntaxRule.quoted("\"", crossingLines: true)),
        // `${…}` can't contain `{`, so a scan stops at the next `${`.
        LeoSyntaxRule(.variable, #"\$\{[^{}\n]{0,512}\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?*!$-]"#),
        .words(.keyword, [
            "alias", "break", "case", "continue", "declare", "do", "done", "elif", "else", "esac", "eval", "exec",
            "exit", "export", "fi", "for", "function", "if", "in", "local", "readonly", "return", "select", "shift",
            "source", "then", "time", "trap", "typeset", "unset", "until", "while",
        ]),
    ])
}
