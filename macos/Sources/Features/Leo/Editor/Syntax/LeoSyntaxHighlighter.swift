import AppKit

enum LeoSyntaxToken: String, CaseIterable, Sendable {
    case keyword, type, string, comment, number, literal, attribute, variable, key, heading, code, emphasis, link
}

struct LeoSyntaxSpan: Equatable, Sendable {
    let range: NSRange
    let token: LeoSyntaxToken
}

/// Regex-based highlighting: each language's rules are joined into one
/// alternation, so a single left-to-right scan decides every span. The
/// leftmost match wins, and among rules matching at the same place the
/// earlier one -- which is what keeps `//` inside a string a string, and a
/// quote inside a comment a comment.
enum LeoSyntaxHighlighter {
    static func spans(in text: String, language: LeoEditorLanguage) -> [LeoSyntaxSpan] {
        spans(in: text, range: NSRange(location: 0, length: (text as NSString).length), language: language)
    }

    /// Only matches wholly inside `range` (a construct that starts before
    /// it, like an open block comment, is missed).
    static func spans(in text: String, range: NSRange, language: LeoEditorLanguage) -> [LeoSyntaxSpan] {
        guard let compiled = LeoCompiledGrammar.all[language] else { return [] }
        return compiled.regex.matches(in: text, range: range).compactMap { match in
            for (index, token) in compiled.tokens.enumerated() {
                let range = match.range(at: index + 1)
                if range.location != NSNotFound, range.length > 0 { return LeoSyntaxSpan(range: range, token: token) }
            }
            return nil
        }
    }

    /// Resets `range` (default: everything) to the plain font and colour,
    /// then colours its spans.
    static func apply(to storage: NSTextStorage, language: LeoEditorLanguage, theme: LeoSyntaxTheme, in range: NSRange? = nil) {
        let target = range ?? NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttributes([.font: theme.font, .foregroundColor: theme.plainColor], range: target)
        for span in spans(in: storage.string, range: target, language: language) {
            storage.addAttribute(.foregroundColor, value: theme.color(for: span.token), range: span.range)
            if theme.isBold(span.token) { storage.addAttribute(.font, value: theme.boldFont, range: span.range) }
        }
        storage.endEditing()
    }
}

/// One highlighting rule: every match of `pattern` is a `token` span.
/// Patterns must not capture (use `(?:…)`): rules are told apart by their
/// group number in the joined alternation.
struct LeoSyntaxRule: Sendable {
    let token: LeoSyntaxToken
    let pattern: String

    init(_ token: LeoSyntaxToken, _ pattern: String) {
        self.token = token
        self.pattern = pattern
    }

    /// `\b(?:a|b|…)\b`.
    static func words(_ token: LeoSyntaxToken, _ words: [String]) -> LeoSyntaxRule {
        LeoSyntaxRule(token, #"\b(?:"# + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#)
    }

    static func lineComment(_ prefix: String) -> LeoSyntaxRule {
        LeoSyntaxRule(.comment, NSRegularExpression.escapedPattern(for: prefix) + #"[^\n]*"#)
    }

    /// `/* … */`; an unterminated one runs to the end.
    static let blockComment = LeoSyntaxRule(.comment, #"/\*[\s\S]*?(?:\*/|\z)"#)
    static let doubleQuoted = LeoSyntaxRule(.string, #""(?:[^"\\\n]|\\.)*""#)
    static let singleQuoted = LeoSyntaxRule(.string, #"'(?:[^'\\\n]|\\.)*'"#)
    /// C-family literals: hex, binary, octal, decimal with fraction/exponent.
    static let number = LeoSyntaxRule(
        .number,
        #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][+-]?[0-9]+)?)\b"#
    )
    /// `@Name` -- Swift attributes, Zig builtins, decorators.
    static let atName = LeoSyntaxRule(.attribute, #"@[A-Za-z_][A-Za-z0-9_]*"#)
    static let capitalizedType = LeoSyntaxRule(.type, #"\b[A-Z][A-Za-z0-9_]*\b"#)
}

/// A language's ordered rules (earlier rules win ties).
struct LeoSyntaxGrammar: Sendable {
    /// `^`/`$` match at line boundaries; `.` never crosses a line.
    static let options: NSRegularExpression.Options = [.anchorsMatchLines]

    let rules: [LeoSyntaxRule]

    static func grammar(for language: LeoEditorLanguage) -> LeoSyntaxGrammar {
        switch language {
        case .swift: .swift
        case .zig: .zig
        case .go: .go
        case .python: .python
        case .javascript: .javaScript
        case .typescript: .typeScript
        case .json: .json
        case .markdown: .markdown
        case .shell: .shell
        case .yaml: .yaml
        case .toml: .toml
        case .plainText: LeoSyntaxGrammar(rules: [])
        }
    }
}

/// Every grammar's rules joined into one regex, built once.
private struct LeoCompiledGrammar {
    let regex: NSRegularExpression
    let tokens: [LeoSyntaxToken]

    static let all: [LeoEditorLanguage: LeoCompiledGrammar] = {
        var compiled: [LeoEditorLanguage: LeoCompiledGrammar] = [:]
        for language in LeoEditorLanguage.allCases {
            let rules = LeoSyntaxGrammar.grammar(for: language).rules
            guard !rules.isEmpty else { continue }
            let pattern = rules.map { "(\($0.pattern))" }.joined(separator: "|")
            guard let regex = try? NSRegularExpression(pattern: pattern, options: LeoSyntaxGrammar.options) else {
                assertionFailure("invalid grammar for \(language)")
                continue
            }
            compiled[language] = LeoCompiledGrammar(regex: regex, tokens: rules.map(\.token))
        }
        return compiled
    }()
}
