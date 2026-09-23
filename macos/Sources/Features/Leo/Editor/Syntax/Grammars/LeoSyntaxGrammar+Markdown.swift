extension LeoSyntaxGrammar {
    static let markdown = LeoSyntaxGrammar(rules: [
        // Fenced code blocks first, so nothing inside them is highlighted.
        LeoSyntaxRule(.code, #"^(?:```|~~~)[^\n]*$[\s\S]*?(?:^(?:```|~~~)[ \t]*$|\z)"#),
        LeoSyntaxRule(.heading, #"^#{1,6}(?:[ \t][^\n]*)?$"#),
        LeoSyntaxRule(.comment, #"^>[^\n]*"#),
        // List markers.
        LeoSyntaxRule(.keyword, #"^[ \t]*(?:[-*+]|[0-9]+[.)])(?=[ \t])"#),
        LeoSyntaxRule(.code, #"`[^`\n]+`"#),
        LeoSyntaxRule(.emphasis, #"\*\*[^*\n]+\*\*|__[^_\n]+__"#),
        LeoSyntaxRule(.emphasis, #"(?<![\w*])\*[^*\s][^*\n]*\*|(?<!\w)_[^_\s][^_\n]*_(?!\w)"#),
        LeoSyntaxRule(.link, #"!?\[[^\]\n]*\]\([^)\n]*\)|<https?://[^>\s]+>"#),
    ])
}
