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
        LeoSyntaxRule(.emphasis, #"\*(?<![\w*]\*)[^*\s][^*\n]*\*|_(?<!\w_)[^_\s][^_\n]*_(?!\w)"#),
        // Link text and URL can't contain `[`, nor an autolink `<`: a scan
        // stops where the next link could start.
        LeoSyntaxRule(.link, #"!?\[[^\[\]\n]{0,512}\]\([^)\[\]\n]{0,2048}\)|<https?://[^<>\s]{1,2048}>"#),
    ])
}
