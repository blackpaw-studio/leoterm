import AppKit
import Foundation
import Testing

@testable import Ghostty

/// Snapshots of the built-in highlighter: each sample's spans, in order,
/// as `token text` lines.
struct LeoSyntaxHighlighterTests {
    private func snapshot(_ text: String, _ language: LeoEditorLanguage) -> [String] {
        let source = text as NSString
        return LeoSyntaxHighlighter.spans(in: text, language: language).map { span in
            "\(span.token) \(source.substring(with: span.range))"
        }
    }

    @Test func swift() {
        let sample = """
        // Leo
        @MainActor let x: Int = 0x1F /* note */
        print("a // b", nil, letter, format)
        """
        #expect(snapshot(sample, .swift) == [
            "comment // Leo",
            "attribute @MainActor",
            "keyword let",
            "type Int",
            "number 0x1F",
            "comment /* note */",
            "string \"a // b\"",
            "literal nil",
        ])
    }

    @Test func zig() {
        let sample = """
        const std = @import("std");
        pub fn main() !void { // hi
            var n: u32 = 42;
        }
        """
        #expect(snapshot(sample, .zig) == [
            "keyword const",
            "attribute @import",
            "string \"std\"",
            "keyword pub",
            "keyword fn",
            "type void",
            "comment // hi",
            "keyword var",
            "type u32",
            "number 42",
        ])
    }

    @Test func go() {
        let sample = """
        package main
        func f() error { return nil } // x
        var s = `raw
        line`
        """
        #expect(snapshot(sample, .go) == [
            "keyword package",
            "keyword func",
            "type error",
            "keyword return",
            "literal nil",
            "comment // x",
            "keyword var",
            "string `raw\nline`",
        ])
    }

    @Test func python() {
        let sample = """
        @dataclass
        def f(x=None):
            \"\"\"doc # not a comment\"\"\"
            return f"hi {x}"  # c
        """
        #expect(snapshot(sample, .python) == [
            "attribute @dataclass",
            "keyword def",
            "literal None",
            "string \"\"\"doc # not a comment\"\"\"",
            "keyword return",
            "string f\"hi {x}\"",
            "comment # c",
        ])
    }

    @Test func javaScript() {
        let sample = """
        import { a } from './a.js';
        const t = `x ${a}`; // c
        export default class Foo extends Bar {}
        """
        #expect(snapshot(sample, .javascript) == [
            "keyword import",
            "keyword from",
            "string './a.js'",
            "keyword const",
            "string `x ${a}`",
            "comment // c",
            "keyword export",
            "keyword default",
            "keyword class",
            "type Foo",
            "keyword extends",
            "type Bar",
        ])
    }

    @Test func typeScript() {
        let sample = """
        interface P { n: number; ok?: boolean }
        let v: P | undefined = null;
        """
        #expect(snapshot(sample, .typescript) == [
            "keyword interface",
            "type P",
            "type number",
            "type boolean",
            "keyword let",
            "type P",
            "literal undefined",
            "literal null",
        ])
    }

    @Test func json() {
        let sample = #"{"name": "leo", "n": -1.5e3, "ok": true, "x": null}"#
        #expect(snapshot(sample, .json) == [
            "key \"name\"",
            "string \"leo\"",
            "key \"n\"",
            "number -1.5e3",
            "key \"ok\"",
            "literal true",
            "key \"x\"",
            "literal null",
        ])
    }

    @Test func markdown() {
        let sample = """
        # Title
        Some **bold** and `code` and [a link](https://x.y).
        - item
        ```js
        let x
        ```
        """
        #expect(snapshot(sample, .markdown) == [
            "heading # Title",
            "emphasis **bold**",
            "code `code`",
            "link [a link](https://x.y)",
            "keyword -",
            "code ```js\nlet x\n```",
        ])
    }

    @Test func shell() {
        let sample = """
        #!/bin/bash
        if [ -n "$HOME" ]; then echo 'hi' # c
        fi
        export PATH=$PATH:${X}
        """
        #expect(snapshot(sample, .shell) == [
            "comment #!/bin/bash",
            "keyword if",
            "string \"$HOME\"",
            "keyword then",
            "string 'hi'",
            "comment # c",
            "keyword fi",
            "keyword export",
            "variable $PATH",
            "variable ${X}",
        ])
    }

    @Test func yaml() {
        let sample = """
        # config
        name: leo
        ports:
          - 80
          - "x: y"
          - image: app:1
        enabled: true
        """
        #expect(snapshot(sample, .yaml) == [
            "comment # config",
            "key name",
            "key ports",
            "number 80",
            "string \"x: y\"",
            "key image",
            "key enabled",
            "literal true",
        ])
    }

    @Test func toml() {
        let sample = """
        # deps
        [package]
        name = "leo" # c
        version = 2
        [[bin]]
        ok = true
        """
        #expect(snapshot(sample, .toml) == [
            "comment # deps",
            "heading [package]",
            "key name",
            "string \"leo\"",
            "comment # c",
            "key version",
            "number 2",
            "heading [[bin]]",
            "key ok",
            "literal true",
        ])
    }

    @Test func plainTextHasNoSpans() {
        #expect(snapshot("let x = 1 // not code", .plainText).isEmpty)
    }

    @Test func anUnterminatedBlockCommentRunsToTheEnd() {
        #expect(snapshot("let a /* open\nlet b", .swift) == ["keyword let", "comment /* open\nlet b"])
    }

    /// Rules are joined into one alternation and told apart by group
    /// number; a rule may capture only its span.
    @Test(arguments: LeoEditorLanguage.allCases)
    func everyRuleCompilesWithAtMostItsSpanCaptured(_ language: LeoEditorLanguage) throws {
        for rule in LeoSyntaxGrammar.grammar(for: language).rules {
            let regex = try NSRegularExpression(pattern: rule.pattern, options: LeoSyntaxGrammar.options)
            #expect(regex.numberOfCaptureGroups <= 1, "\(language) \(rule.token): \(rule.pattern)")
        }
    }

    /// A rule's capture group is its span: indentation and list markers
    /// before a YAML key, `key: ` before a value, `{` before an inline
    /// table's key, are matched but not coloured.
    @Test func aCapturedSpanLeavesItsContextPlain() {
        let yaml = "root:\n  - - name: x\n    port: 80\n"
        #expect(snapshot(yaml, .yaml) == ["key root", "key name", "key port", "number 80"])
        #expect(snapshot("t = {a = 1, b = true}\n  c = 2", .toml) == ["key t", "key a", "number 1", "key b", "literal true", "key c", "number 2"])
    }

    @MainActor @Test func applyColorsSpansAndResetsTheRest() throws {
        let theme = LeoSyntaxTheme.system(fontSize: 12)
        let storage = NSTextStorage(string: "let x = 1")
        storage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: NSRange(location: 4, length: 1))

        LeoSyntaxHighlighter.apply(to: storage, language: .swift, theme: theme)

        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == theme.color(for: .keyword))
        #expect(storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor == theme.plainColor)
        #expect(storage.attribute(.foregroundColor, at: 8, effectiveRange: nil) as? NSColor == theme.color(for: .number))
        #expect(storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont == theme.font)
    }
}
