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
///
/// It runs on the main thread, so every rule must stay one pass over the
/// text: a rule may scan far only where a match is then certain (a comment
/// to the line end), or where the next place it could start is past where
/// its scan stops (a string can't start at an escaped quote). Anything
/// else is bounded. Lines over `longLineLimit` are left plain.
enum LeoSyntaxHighlighter {
    /// Longer lines (minified JSON, a log line) are left plain: little to
    /// see, and a lot of regex work.
    static let longLineLimit = 4096

    /// Runs a language's joined regex over one segment of the text. A seam
    /// for tests that count the regex engine's work; the app uses Foundation's.
    typealias Matcher = @Sendable (NSRegularExpression, String, NSRange) -> [NSTextCheckingResult]
    static let foundationMatcher: Matcher = { regex, text, range in regex.matches(in: text, range: range) }

    static func spans(in text: String, language: LeoEditorLanguage, matcher: Matcher = foundationMatcher) -> [LeoSyntaxSpan] {
        spans(in: text, range: NSRange(location: 0, length: (text as NSString).length), language: language, matcher: matcher)
    }

    /// Only matches wholly inside `range` (a construct that starts before
    /// it, like an open block comment, is missed), and none on lines over
    /// `longLineLimit` (a construct spanning one is cut there).
    static func spans(
        in text: String, range: NSRange, language: LeoEditorLanguage, matcher: Matcher = foundationMatcher
    ) -> [LeoSyntaxSpan] {
        guard let compiled = LeoCompiledGrammar.all[language] else { return [] }
        return highlightableRanges(in: text as NSString, range: range).flatMap { segment in
            matcher(compiled.regex, text, segment).compactMap(compiled.span(of:))
        }
    }

    /// `range` without its lines over `limit` (terminator excluded): the
    /// runs of shorter lines between them.
    static func highlightableRanges(in text: NSString, range: NSRange, limit: Int = longLineLimit) -> [NSRange] {
        var ranges: [NSRange] = []
        let end = NSMaxRange(range)
        var runStart = range.location
        var lineStart = range.location
        while lineStart < end {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let next = min(lineEnd, end)
            if min(contentsEnd, end) - lineStart > limit {
                if lineStart > runStart { ranges.append(NSRange(location: runStart, length: lineStart - runStart)) }
                runStart = next
            }
            lineStart = next
        }
        if end > runStart { ranges.append(NSRange(location: runStart, length: end - runStart)) }
        return ranges
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

/// One highlighting rule: every match of `pattern` is a `token` span --
/// or, if the pattern has a capture group, just what that captured
/// (context to skip, like a YAML key's indentation, without a costly
/// lookbehind). At most one capture group: use `(?:…)` for the rest.
struct LeoSyntaxRule: Sendable {
    let token: LeoSyntaxToken
    let pattern: String

    init(_ token: LeoSyntaxToken, _ pattern: String) {
        self.token = token
        self.pattern = pattern
    }

    /// `\b(?:a|b|…)\b`, grouped by first letter (`\b(?:a(?:s|sync)|b…)\b`):
    /// the regex engine tries alternatives one by one, and a keyword list
    /// is tried at every word.
    static func words(_ token: LeoSyntaxToken, _ words: [String]) -> LeoSyntaxRule {
        let groups = Dictionary(grouping: words.filter { !$0.isEmpty }, by: \.first!).sorted { $0.key < $1.key }
        let alternatives = groups.map { first, words in
            let rests = words.map { NSRegularExpression.escapedPattern(for: String($0.dropFirst())) }
            return NSRegularExpression.escapedPattern(for: String(first)) + "(?:" + rests.joined(separator: "|") + ")"
        }
        return LeoSyntaxRule(token, #"\b(?:"# + alternatives.joined(separator: "|") + #")\b"#)
    }

    static func lineComment(_ prefix: String) -> LeoSyntaxRule {
        LeoSyntaxRule(.comment, NSRegularExpression.escapedPattern(for: prefix) + #"[^\n]*"#)
    }

    /// `/* … */`; an unterminated one runs to the end.
    static let blockComment = LeoSyntaxRule(.comment, #"/\*[\s\S]*?(?:\*/|\z)"#)
    static let doubleQuoted = LeoSyntaxRule(.string, quoted("\""))
    static let singleQuoted = LeoSyntaxRule(.string, quoted("'"))

    /// A string between `quote`s, with backslash escapes. It never starts
    /// at an escaped quote, so an unterminated one is scanned once, not
    /// again from each escaped quote in it (`"\"\"\"…`); the possessive
    /// `*+` never backtracks into what it scanned. (The quote comes before
    /// the lookbehind so the engine can skip to quotes.)
    static func quoted(_ quote: Character, crossingLines: Bool = false) -> String {
        let other = crossingLines ? #"[^\#(quote)\\]"# : #"[^\#(quote)\\\n]"#
        let escape = crossingLines ? #"\\[\s\S]"# : #"\\."#
        return #"\#(quote)(?<!\\\#(quote))(?:\#(other)|\#(escape))*+\#(quote)"#
    }

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
    /// A rule's group in the joined regex, and the group holding its span
    /// (the same one, unless the rule captures its span itself).
    struct Rule {
        let token: LeoSyntaxToken
        let group: Int
        let spanGroup: Int
    }

    let regex: NSRegularExpression
    let rules: [Rule]

    /// The first rule that matched: rules never overlap, since a match is
    /// exactly one alternative.
    func span(of match: NSTextCheckingResult) -> LeoSyntaxSpan? {
        guard let rule = rules.first(where: { match.range(at: $0.group).location != NSNotFound }) else { return nil }
        let range = match.range(at: rule.spanGroup)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return LeoSyntaxSpan(range: range, token: rule.token)
    }

    static let all: [LeoEditorLanguage: LeoCompiledGrammar] = {
        var compiled: [LeoEditorLanguage: LeoCompiledGrammar] = [:]
        for language in LeoEditorLanguage.allCases {
            let grammar = LeoSyntaxGrammar.grammar(for: language).rules
            guard !grammar.isEmpty else { continue }
            var rules: [Rule] = []
            var group = 1
            for rule in grammar {
                let captures = (try? NSRegularExpression(pattern: rule.pattern, options: LeoSyntaxGrammar.options))?.numberOfCaptureGroups ?? 0
                assert(captures <= 1, "\(language) \(rule.token) captures more than its span")
                rules.append(Rule(token: rule.token, group: group, spanGroup: captures == 1 ? group + 1 : group))
                group += 1 + captures
            }
            let pattern = grammar.map { "(\($0.pattern))" }.joined(separator: "|")
            guard let regex = try? NSRegularExpression(pattern: pattern, options: LeoSyntaxGrammar.options) else {
                assertionFailure("invalid grammar for \(language)")
                continue
            }
            compiled[language] = LeoCompiledGrammar(regex: regex, rules: rules)
        }
        return compiled
    }()
}
