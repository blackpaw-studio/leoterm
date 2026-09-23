import Testing

@testable import Ghostty

struct LeoEditorLanguageTests {
    @Test(arguments: [
        ("/w/App.swift", LeoEditorLanguage.swift),
        ("/w/MAIN.SWIFT", .swift),
        ("/w/build.zig", .zig),
        ("/w/build.zig.zon", .zig),
        ("/w/main.go", .go),
        ("/w/tool.py", .python),
        ("/w/stubs.pyi", .python),
        ("/w/index.js", .javascript),
        ("/w/index.mjs", .javascript),
        ("/w/index.cjs", .javascript),
        ("/w/App.jsx", .javascript),
        ("/w/index.ts", .typescript),
        ("/w/App.tsx", .typescript),
        ("/w/mod.mts", .typescript),
        ("/w/package.json", .json),
        ("/w/tsconfig.jsonc", .json),
        ("/w/README.md", .markdown),
        ("/w/notes.markdown", .markdown),
        ("/w/run.sh", .shell),
        ("/w/run.bash", .shell),
        ("/w/run.zsh", .shell),
        ("/Users/e/.zshrc", .shell),
        ("/Users/e/.bashrc", .shell),
        ("/Users/e/.profile", .shell),
        ("/w/ci.yml", .yaml),
        ("/w/ci.yaml", .yaml),
        ("/w/Cargo.toml", .toml),
        ("/w/Makefile", .plainText),
        ("/w/notes.txt", .plainText),
        ("/w/LICENSE", .plainText),
        ("/w/dir.swift/inside", .plainText),
        ("/w/.gitignore", .plainText),
    ])
    func picksTheLanguageFromTheExtension(_ path: String, expected: LeoEditorLanguage) {
        #expect(LeoEditorLanguage(path: path) == expected)
    }

    @Test func everyLanguageHasADisplayName() {
        #expect(LeoEditorLanguage.allCases.allSatisfy { !$0.displayName.isEmpty })
        #expect(LeoEditorLanguage.typescript.displayName == "TypeScript")
        #expect(LeoEditorLanguage.plainText.displayName == "Plain Text")
    }
}
