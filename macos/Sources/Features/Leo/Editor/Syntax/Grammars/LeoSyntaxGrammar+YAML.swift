extension LeoSyntaxGrammar {
    /// Where a YAML value starts: after `key: ` or `- `, or at a line start.
    private static let yamlValueStart = #"(?:(?<=:[ \t]{1,20})|(?<=-[ \t]{1,20})|^)"#
    /// A value ends at the line end or a comment.
    private static let yamlValueEnd = #"(?=[ \t]*(?:#|$))"#

    static let yaml = LeoSyntaxGrammar(rules: [
        LeoSyntaxRule(.comment, #"(?<!\S)#[^\n]*"#),
        .doubleQuoted,
        LeoSyntaxRule(.string, #"'(?:[^'\n]|'')*'"#),
        LeoSyntaxRule(.keyword, #"^(?:---|\.\.\.)[ \t]*$"#),
        LeoSyntaxRule(.key, #"(?:^|(?<=^[ \t]{1,40})|(?<=-[ \t]))[A-Za-z0-9_][A-Za-z0-9_.\-/ ]*?(?=[ \t]*:(?:[ \t]|$))"#),
        // Anchors and aliases.
        LeoSyntaxRule(.variable, #"[&*][A-Za-z0-9_\-]+"#),
        LeoSyntaxRule(.attribute, #"!{1,2}[A-Za-z][A-Za-z0-9_\-]*"#),
        LeoSyntaxRule(.literal, yamlValueStart + #"(?:true|false|null|yes|no|on|off|True|False|Null|TRUE|FALSE|NULL|~)"# + yamlValueEnd),
        LeoSyntaxRule(
            .number,
            yamlValueStart + #"[-+]?(?:0x[0-9a-fA-F]+|[0-9][0-9_]*(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|\.inf|\.nan)"# + yamlValueEnd
        ),
    ])
}
