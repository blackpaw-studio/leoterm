extension LeoSyntaxGrammar {
    /// Where a YAML value starts: after `key: ` or `- `, or at a line start.
    /// Matched (not looked behind at, which costs at every position) and
    /// left out of the span, which is the capture group that follows.
    private static let yamlValueStart = #"(?:[:-][ \t]{1,20}+|^)"#
    /// A value ends at the line end or a comment.
    private static let yamlValueEnd = #"(?=[ \t]*(?:#|$))"#

    static let yaml = LeoSyntaxGrammar(rules: [
        // Lookbehinds come after the first character, so the engine can
        // skip to it.
        LeoSyntaxRule(.comment, #"#(?<!\S#)[^\n]*"#),
        .doubleQuoted,
        LeoSyntaxRule(.string, #"'(?:[^'\n]|'')*'"#),
        LeoSyntaxRule(.keyword, #"^(?:---|\.\.\.)[ \t]*$"#),
        // A key starts a line, after its indentation and any `- ` list
        // markers (matched, and left out of the span). Bounded: a key can
        // hold spaces, so an unbounded one would scan every line to its end.
        LeoSyntaxRule(.key, #"^[ \t]{0,40}+(?:-[ \t]+){0,3}+([A-Za-z0-9_][A-Za-z0-9_.\-/ ]{0,256}?)(?=[ \t]{0,40}:(?:[ \t]|$))"#),
        // Anchors and aliases.
        LeoSyntaxRule(.variable, #"[&*][A-Za-z0-9_\-]+"#),
        LeoSyntaxRule(.attribute, #"!{1,2}[A-Za-z][A-Za-z0-9_\-]*"#),
        LeoSyntaxRule(.literal, yamlValueStart + #"(true|false|null|yes|no|on|off|True|False|Null|TRUE|FALSE|NULL|~)"# + yamlValueEnd),
        LeoSyntaxRule(
            .number,
            yamlValueStart + #"([-+]?(?:0x[0-9a-fA-F]+|[0-9][0-9_]*(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|\.inf|\.nan))"# + yamlValueEnd
        ),
    ])
}
