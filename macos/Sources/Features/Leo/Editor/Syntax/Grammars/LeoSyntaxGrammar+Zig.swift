extension LeoSyntaxGrammar {
    static let zig = LeoSyntaxGrammar(rules: [
        .lineComment("//"),
        // `\\` multiline string lines.
        LeoSyntaxRule(.string, #"\\\\[^\n]*"#),
        .doubleQuoted,
        .singleQuoted,
        .atName,
        .number,
        .words(.literal, ["true", "false", "null", "undefined"]),
        LeoSyntaxRule(
            .type,
            #"\b(?:[iu][1-9][0-9]*|f16|f32|f64|f80|f128|usize|isize|bool|void|type|anyerror|anyopaque|anytype|noreturn|comptime_int|comptime_float|c_char|c_short|c_ushort|c_int|c_uint|c_long|c_ulong|c_longlong|c_ulonglong|c_longdouble)\b"#
        ),
        .words(.keyword, [
            "addrspace", "align", "allowzero", "and", "anyframe", "asm", "async", "await", "break", "callconv",
            "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export",
            "extern", "fn", "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend", "opaque",
            "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test",
            "threadlocal", "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while",
        ]),
        .capitalizedType,
    ])
}
