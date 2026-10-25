import Testing

@testable import LeoKit

struct LeoTaskPromptFileTests {
    @Test(arguments: ["prompts/nightly.md", "heartbeat.md", "a b/c.md", "notes.txt"])
    func aRelativeNameInsideTheWorkspaceIsFine(path: String) {
        #expect(LeoTaskPromptFile.problem(with: path) == nil)
    }

    @Test(arguments: ["", "   ", "/etc/passwd", "../x.md", "a/../../x.md", "a/./b.md", "a//b.md", "dir/", "a\\b.md", "x\n.md"])
    func anEmptyAbsoluteOrTravellingNameIsRefused(path: String) {
        #expect(LeoTaskPromptFile.problem(with: path) != nil)
    }

    @Test func theMessageSaysWhy() {
        #expect(LeoTaskPromptFile.problem(with: "../x.md") == "A prompt file stays inside the workspace: no “..” or leading “/”.")
        #expect(LeoTaskPromptFile.problem(with: "") == "Name the prompt file.")
    }
}
