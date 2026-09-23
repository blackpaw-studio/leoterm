extension LeoSyntaxGrammar {
    static let shell = LeoSyntaxGrammar(rules: [
        // `#` starts a comment only at the start of a word.
        LeoSyntaxRule(.comment, #"(?<![^\s;|&(])#[^\n]*"#),
        LeoSyntaxRule(.string, #"'[^']*'"#),
        LeoSyntaxRule(.string, #""(?:[^"\\]|\\[\s\S])*""#),
        LeoSyntaxRule(.variable, #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?*!$-]"#),
        .words(.keyword, [
            "alias", "break", "case", "continue", "declare", "do", "done", "elif", "else", "esac", "eval", "exec",
            "exit", "export", "fi", "for", "function", "if", "in", "local", "readonly", "return", "select", "shift",
            "source", "then", "time", "trap", "typeset", "unset", "until", "while",
        ]),
    ])
}
