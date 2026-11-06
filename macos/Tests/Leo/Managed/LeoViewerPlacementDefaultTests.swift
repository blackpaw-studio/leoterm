import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-341: only a `leo.yaml` with no `defaults.dispatch.viewer.placement` is
/// given `placement: window`, by adding the missing part of the key path as
/// new lines; any explicit value or anything ambiguous is left exactly as it is.
struct LeoViewerPlacementDefaultTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let input: String
        let output: String
        var testDescription: String { input.debugDescription }
    }

    static let window = ["dispatch:", "viewer:", "placement: window"]

    /// `lines` indented from `indent` in steps of `step`, one level each.
    static func nested(_ lines: [String], indent: Int, step: Int) -> String {
        lines.enumerated().map { String(repeating: " ", count: indent + $0.offset * step) + $0.element }.joined(separator: "\n")
    }

    static let inserts: [Case] = [
        // The laptop's shape, 2-space indent: the whole `dispatch` path, first under `defaults`.
        Case(
            input: "defaults:\n  model: sonnet\ntemplates:\n  assistant:\n    model: opus\ntasks: []\n",
            output: "defaults:\n" + nested(window, indent: 2, step: 2) + "\n  model: sonnet\ntemplates:\n  assistant:\n    model: opus\ntasks: []\n"
        ),
        // 4-space indent is copied.
        Case(
            input: "defaults:\n    model: sonnet\ntemplates:\n    assistant:\n        model: opus\n",
            output: "defaults:\n" + nested(window, indent: 4, step: 4) + "\n    model: sonnet\ntemplates:\n    assistant:\n        model: opus\n"
        ),
        // An existing `dispatch` gets only `viewer` + `placement`.
        Case(
            input: "defaults:\n  dispatch:\n    max_concurrent: 4\n",
            output: "defaults:\n  dispatch:\n" + nested(["viewer:", "placement: window"], indent: 4, step: 2) + "\n    max_concurrent: 4\n"
        ),
        // An existing `viewer` gets only `placement`.
        Case(
            input: "defaults:\n  model: sonnet\n  dispatch:\n    viewer:\n      max_panes: 3\n",
            output: "defaults:\n  model: sonnet\n  dispatch:\n    viewer:\n      placement: window\n      max_panes: 3\n"
        ),
        // No `defaults`: a whole block before the first top-level key, with or without a trailing newline.
        Case(
            input: "templates:\n  assistant:\n    model: opus\n",
            output: nested(["defaults:"] + window, indent: 0, step: 2) + "\ntemplates:\n  assistant:\n    model: opus\n"
        ),
        Case(input: "tasks: []", output: nested(["defaults:"] + window, indent: 0, step: 2) + "\ntasks: []"),
        Case(input: "", output: nested(["defaults:"] + window, indent: 0, step: 2) + "\n"),
        Case(input: "# only a comment\n", output: "# only a comment\n" + nested(["defaults:"] + window, indent: 0, step: 2) + "\n"),
        Case(input: "---\ntasks: []\n", output: "---\n" + nested(["defaults:"] + window, indent: 0, step: 2) + "\ntasks: []\n"),
        // `defaults:` with no children: indent + the file's step.
        Case(input: "defaults:\ntasks: []\n", output: "defaults:\n" + nested(window, indent: 2, step: 2) + "\ntasks: []\n"),
        Case(input: "defaults:", output: "defaults:\n" + nested(window, indent: 2, step: 2)),
        Case(
            input: "defaults:\ntemplates:\n    assistant: {}\n",
            output: "defaults:\n" + nested(window, indent: 4, step: 4) + "\ntemplates:\n    assistant: {}\n"
        ),
        // Trailing comments on the path lines, comments between entries, quoted keys, a BOM.
        Case(
            input: "defaults: # mine\n  # tuned by hand\n  dispatch:   # tune\n    max_concurrent: 2\n",
            output: "defaults: # mine\n  # tuned by hand\n  dispatch:   # tune\n" + nested(["viewer:", "placement: window"], indent: 4, step: 2)
                + "\n    max_concurrent: 2\n"
        ),
        Case(
            input: "\"defaults\" :\n  'dispatch':\n    max_concurrent: 2\n",
            output: "\"defaults\" :\n  'dispatch':\n" + nested(["viewer:", "placement: window"], indent: 4, step: 2) + "\n    max_concurrent: 2\n"
        ),
        Case(
            input: "\u{FEFF}# leo\ndefaults:\n  # the model\n  model: sonnet\n",
            output: "\u{FEFF}# leo\ndefaults:\n" + nested(window, indent: 2, step: 2) + "\n  # the model\n  model: sonnet\n"
        ),
        // A block scalar whose text looks like keys is not the path.
        Case(
            input: "defaults:\n  prompt: |\n    dispatch:\n      viewer:\n  model: sonnet\n",
            output: "defaults:\n" + nested(window, indent: 2, step: 2) + "\n  prompt: |\n    dispatch:\n      viewer:\n  model: sonnet\n"
        ),
    ]

    @Test(arguments: inserts)
    func aMissingPlacementIsAddedAsNewLines(example: Case) {
        #expect(LeoViewerPlacementDefault.migrate(yaml: example.input, pathKind: .file) == .insert(example.output))
    }

    /// Removing the added lines gives back the input byte for byte: comments,
    /// BOM and trailing newline included.
    @Test(arguments: inserts)
    func onlyLinesAreAdded(example: Case) throws {
        guard case let .insert(output) = LeoViewerPlacementDefault.migrate(yaml: example.input, pathKind: .file) else {
            Issue.record("expected .insert for \(example.input.debugDescription)")
            return
        }
        let added = Set(["defaults:"] + Self.window)
        var input = example.input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var remaining: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let next = input.first, next == line {
                input.removeFirst()
                remaining.append(line)
            } else {
                #expect(added.contains(line.trimmingCharacters(in: .whitespaces)), "unexpected line \(line.debugDescription)")
            }
        }
        #expect(remaining.joined(separator: "\n") == example.input)
    }

    @Test(arguments: [
        "defaults:\n  dispatch:\n    viewer:\n      placement: pane\n",
        "defaults:\n  dispatch:\n    viewer:\n      placement: window\n",
        "defaults:\n  dispatch:\n    viewer:\n      placement: background\n",
        "defaults:\n  dispatch:\n    viewer:\n      placement: \"\"\n",
        "defaults:\n  dispatch:\n    viewer:\n      placement:\n",
        "defaults:\n  dispatch:\n    viewer:\n      placement: bogus # typo\n",
        "defaults:\n  dispatch:\n    viewer:\n      max_panes: 2\n      \"placement\": pane\n",
        "defaults:\n    dispatch:\n        viewer:\n            placement: pane\n",
    ])
    func anyExistingPlacementIsPresent(yaml: String) {
        #expect(LeoViewerPlacementDefault.migrate(yaml: yaml, pathKind: .file) == .present)
    }

    @Test(arguments: [
        // A follower: the lead's shared config may set the placement.
        "follow:\n  lead: http://lead:8370\ndefaults:\n  model: sonnet\n",
        // Flow collections on the path.
        "{defaults: {}}\n",
        "defaults: {}\n",
        "defaults:\n  dispatch: {viewer: {max_panes: 2}}\n",
        "defaults:\n  dispatch:\n    viewer: {}\n",
        // Merge keys, anchors and aliases.
        "<<: *base\ndefaults:\n  model: sonnet\n",
        "base: &base\n  model: x\ndefaults:\n  <<: *base\n",
        "defaults: &d\n  model: x\n",
        "defaults:\n  dispatch: *d\n",
        "defaults:\n  model: &m sonnet\n",
        "&a defaults:\n  model: x\n",
        // Explicit null or a scalar where a mapping is needed.
        "defaults:\n  dispatch:\n    viewer: null\n",
        "defaults:\n  dispatch:\n    viewer: ~\n",
        "defaults: none\n",
        "defaults:\n  dispatch: |\n    text\n",
        // Sequences where a mapping is needed.
        "- a\n- b\n",
        "defaults:\n- a\n",
        "defaults:\n  dispatch:\n    - a\n",
        // A line at a scanned level that isn't `key:` or a comment.
        "defaults:\n  just text\n",
        "defaults:\n  ? complex\n  : value\n",
        "defaults:\n  !!map\n  model: x\n",
        "\"def\\u0061ults\":\n  model: x\n",
        // More than one document, or a document end.
        "defaults:\n  model: x\n---\ntasks: []\n",
        "tasks: []\n...\n",
        "--- {defaults: {}}\n",
        // Tabs, CR and other line breaks.
        "defaults:\n\tmodel: x\n",
        "defaults:\n  dispatch:\n  \tviewer: {}\n",
        "defaults:\r\n  model: x\r\n",
        "defaults:\n  model: x\u{2028}tasks: []\n",
        // Inconsistent indentation and repeated keys.
        "defaults:\n    model: x\n  dispatch:\n    max_concurrent: 2\n",
        "defaults:\n  model: x\ndefaults:\n  model: y\n",
        "defaults:\n  dispatch:\n    viewer:\n      placement: pane\n      placement: window\n",
    ])
    func ambiguousShapesAreSkipped(yaml: String) {
        guard case .skip = LeoViewerPlacementDefault.migrate(yaml: yaml, pathKind: .file) else {
            Issue.record("expected .skip for \(yaml.debugDescription)")
            return
        }
    }

    @Test(arguments: [LeoPathKind.absent, .directory, .symlink(target: "/elsewhere/leo.yaml")])
    func onlyARegularFileIsConsidered(kind: LeoPathKind) {
        guard case .skip = LeoViewerPlacementDefault.migrate(yaml: "defaults:\n  model: sonnet\n", pathKind: kind) else {
            Issue.record("expected .skip for \(kind)")
            return
        }
    }
}
