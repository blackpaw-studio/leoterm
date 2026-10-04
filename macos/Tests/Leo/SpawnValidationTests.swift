import Combine
import Foundation
import Testing
@testable import Ghostty

struct SpawnValidationTests {
    @Test(arguments: [
        ("alpha", nil), ("-alpha", "Name cannot begin with -"),
        ("two words", "Name may only contain letters, numbers, ., _, and -"),
        ("alpha/one", "Name may only contain letters, numbers, ., _, and -")
    ]) func nameRules(value: String, expected: String?) {
        #expect(SpawnValidation.name(value) == expected)
    }

    @Test func templateIsRequiredAndRepositoryIsOptional() {
        #expect(SpawnValidation.spawn(template: "", repo: "/repo", name: nil, pathExists: { _ in true }) == "Template is required")
        #expect(SpawnValidation.spawn(template: "swift", repo: "", name: nil, pathExists: { _ in false }) == nil)
        #expect(SpawnValidation.spawn(template: "swift", repo: "/missing", name: nil, pathExists: { _ in false }) == "Choose an existing repository")
        #expect(SpawnValidation.spawn(template: "swift", repo: "/repo", name: "ok", pathExists: { _ in true }) == nil)
    }

    @Test @MainActor func selectedTemplateMustBeFetched() {
        let list = Just(LeoTemplateListState.loaded([LeoTemplate(name: "swift")])).eraseToAnyPublisher()
        let model = SpawnAgentModel(templateList: list)
        model.template = "missing"
        #expect(model.validationError == "Choose an available template")
        model.template = "swift"
        #expect(model.validationError == nil)
    }

    @Test(arguments: [
        ("", "Name is required"), ("same", "Name is unchanged"),
        ("two words", "Name cannot contain whitespace or /"), ("a/b", "Name cannot contain whitespace or /"),
        ("new-name", nil)
    ]) func renameRules(value: String, expected: String?) {
        #expect(SpawnValidation.rename(value, current: "same") == expected)
    }

    /// B-176: a worktree spawn needs the daemon's owner/repo form, never a path.
    @Test(arguments: [
        ("evandcoleman/chronicle", "evandcoleman/chronicle"), ("blackpaw-studio/website", "blackpaw-studio/website")
    ]) func ownerRepoAcceptsOnlyOwnerSlashRepo(value: String, expected: String) {
        #expect(SpawnValidation.ownerRepo(value) == expected)
    }

    @Test(arguments: [nil, "", "ancestry", "/x", "a/", "a/b/c", "a b/c", "a/b c", "/Users/evan/repo"] as [String?])
    func ownerRepoRejectsEverythingElse(value: String?) {
        #expect(SpawnValidation.ownerRepo(value) == nil)
    }

    @Test func worktreeValidationRequiresBranch() {
        #expect(SpawnValidation.worktree(template: "claude", repo: "o/r", branch: "", name: nil) == "Branch is required")
        #expect(SpawnValidation.worktree(template: "claude", repo: "o/r", branch: "feat/a11y", name: nil) == nil)
        #expect(SpawnValidation.worktree(template: "", repo: "o/r", branch: "feat/a11y", name: nil) == "Template is required")
        #expect(SpawnValidation.worktree(template: "claude", repo: "brand", branch: "feat/a11y", name: nil) != nil)
        #expect(SpawnValidation.worktree(template: "claude", repo: "o/r", branch: "feat/a11y", name: "-x") == "Name cannot begin with -")
    }

    @Test(arguments: [
        "-x", "a b", "a..b", "x.lock", "x/", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a\tb", "/x", "a//b", "a@{b", "x."
    ]) func worktreeValidationRejectsInvalidBranch(branch: String) {
        #expect(SpawnValidation.worktree(template: "claude", repo: "o/r", branch: branch, name: nil) != nil)
    }
}
