import Foundation

/// Pure, stateless validation logic for the spawn-agent sheet. Kept separate
/// from the view so it is easily unit-tested without SwiftUI.
enum SpawnValidation {
    /// Validates the spawn parameters and returns a human-readable problem
    /// description, or `nil` when the inputs are valid and spawning may proceed.
    ///
    /// - Parameters:
    ///   - template: The selected template name.
    ///   - repo: The repository value entered by the user.
    ///   - branch: The optional branch value entered by the user.
    static func validate(template: String, repo: String, branch: String) -> String? {
        if repo.isEmpty { return "Repository is required." }
        if !branch.isEmpty, !isGitHubRepo(repo) {
            return "A branch requires a GitHub repo in owner/name form"
        }
        return nil
    }

    /// Returns true when `repo` matches the `owner/name` pattern expected by the
    /// leo CLI for branch-scoped spawns: exactly one slash, no whitespace, and
    /// non-empty owner and name segments.
    static func isGitHubRepo(_ repo: String) -> Bool {
        let parts = repo.components(separatedBy: "/")
        guard parts.count == 2 else { return false }
        let owner = parts[0], name = parts[1]
        let hasWhitespace: (String) -> Bool = { $0.contains(where: \.isWhitespace) }
        return !owner.isEmpty && !name.isEmpty &&
            !hasWhitespace(owner) && !hasWhitespace(name)
    }
}
