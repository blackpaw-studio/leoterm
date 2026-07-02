import Testing
@testable import Ghostty

struct SpawnValidationTests {
    // MARK: - repo required

    @Test func emptyRepoIsInvalid() {
        #expect(SpawnValidation.validate(template: "basic", repo: "", branch: "") != nil)
    }

    @Test func nonEmptyRepoWithoutBranchIsValid() {
        #expect(SpawnValidation.validate(template: "basic", repo: "myworkspace", branch: "") == nil)
    }

    // MARK: - owner/name form with branch

    @Test func ownerSlashNameWithBranchIsValid() {
        #expect(SpawnValidation.validate(template: "basic", repo: "acme/api", branch: "main") == nil)
    }

    @Test func plainWorkspaceNameWithBranchIsInvalid() {
        let hint = SpawnValidation.validate(template: "basic", repo: "myworkspace", branch: "feat/x")
        #expect(hint == "A branch requires a GitHub repo in owner/name form")
    }

    @Test func tooManySlashesWithBranchIsInvalid() {
        let hint = SpawnValidation.validate(template: "basic", repo: "acme/api/v2", branch: "main")
        #expect(hint != nil)
    }

    @Test func noSlashWithBranchIsInvalid() {
        let hint = SpawnValidation.validate(template: "basic", repo: "noSlash", branch: "main")
        #expect(hint != nil)
    }

    @Test func leadingSlashWithBranchIsInvalid() {
        let hint = SpawnValidation.validate(template: "basic", repo: "/name", branch: "main")
        #expect(hint != nil)
    }

    @Test func trailingSlashWithBranchIsInvalid() {
        let hint = SpawnValidation.validate(template: "basic", repo: "owner/", branch: "main")
        #expect(hint != nil)
    }

    @Test func whitespaceInOwnerWithBranchIsInvalid() {
        let hint = SpawnValidation.validate(template: "basic", repo: "my owner/api", branch: "main")
        #expect(hint != nil)
    }

    @Test func whitespaceInNameWithBranchIsInvalid() {
        let hint = SpawnValidation.validate(template: "basic", repo: "owner/my api", branch: "main")
        #expect(hint != nil)
    }

    // MARK: - isGitHubRepo

    @Test func validGitHubRepo() {
        #expect(SpawnValidation.isGitHubRepo("owner/name"))
    }

    @Test func repoWithMultipleSegmentsIsNotGitHub() {
        #expect(!SpawnValidation.isGitHubRepo("owner/name/extra"))
    }

    @Test func repoWithNoSlashIsNotGitHub() {
        #expect(!SpawnValidation.isGitHubRepo("workspace"))
    }

    @Test func emptyStringIsNotGitHub() {
        #expect(!SpawnValidation.isGitHubRepo(""))
    }

    @Test func repoWithLeadingSlashIsNotGitHub() {
        #expect(!SpawnValidation.isGitHubRepo("/name"))
    }

    @Test func repoWithTrailingSlashIsNotGitHub() {
        #expect(!SpawnValidation.isGitHubRepo("owner/"))
    }
}
