import Foundation
import LeoKit

enum SpawnValidation {
    static func name(_ value: String, current: String? = nil) -> String? {
        guard !value.isEmpty else { return nil }
        guard !value.hasPrefix("-") else { return "Name cannot begin with -" }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else { return "Name may only contain letters, numbers, ., _, and -" }
        if value == current { return "Name is unchanged" }
        return nil
    }
    static func rename(_ value: String, current: String) -> String? {
        guard !value.isEmpty else { return "Name is required" }
        guard !value.contains(where: { $0.isWhitespace || $0 == "/" }) else { return "Name cannot contain whitespace or /" }
        return name(value, current: current)
    }
    /// `repo` is optional: blank, a bare name, or `owner/repo`, the daemon's
    /// `ValidateRepo` rule, which is the same on every machine. A repository
    /// is required once a branch is given.
    static func spawn(template: String?, repo: String, name: String?, branch: String = "") -> String? {
        guard let template, !template.isEmpty else { return "Template is required" }
        let normalized = normalizedRepo(repo)
        if normalized.isEmpty, !branch.isEmpty { return "Branch needs a repository" }
        guard isValidRepo(normalized) else { return "Repository must be owner/repo (or a bare name)" }
        return name.flatMap { Self.name($0) }
    }

    /// Trimmed, with a pasted `https://github.com/owner/repo[.git][/]` reduced
    /// to `owner/repo`.
    static func normalizedRepo(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: githubURLPrefix, options: [.anchored, .caseInsensitive]) else { return trimmed }
        var rest = String(trimmed[range.upperBound...])
        if rest.hasSuffix("/") { rest.removeLast() }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        return rest
    }

    /// Mirrors the daemon's `ValidateRepo`: empty, a bare name, or exactly
    /// `owner/repo` with no empty segment; no whitespace, no `~` home path, and no `.`/`..` segment.
    private static func isValidRepo(_ repo: String) -> Bool {
        guard !repo.hasPrefix("~"), !repo.contains(where: \.isWhitespace) else { return false }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        return repo.isEmpty || (parts.count <= 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." })
    }

    private static let githubURLPrefix = "https://github.com/"

    /// `repo` when it is the daemon's GitHub `owner/repo` form (exactly one
    /// "/", both sides non-empty, no whitespace), which a worktree spawn
    /// requires; nil for a path, a bare name, or nothing.
    static func ownerRepo(_ repo: String?) -> String? {
        guard let repo, !repo.contains(where: \.isWhitespace) else { return nil }
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return repo
    }

    /// B-176: a spawn into a new worktree branch of an owner/repo. No local
    /// path check: the repository may live on a remote host.
    static func worktree(template: String?, repo: String, branch: String, name: String?) -> String? {
        guard let template, !template.isEmpty else { return "Template is required" }
        guard ownerRepo(repo) != nil else { return "Repository must be owner/repo" }
        if let error = self.branch(branch) { return error }
        return name.flatMap { Self.name($0) }
    }

    /// The subset of `git check-ref-format` a typed branch name can trip.
    static func branch(_ value: String) -> String? {
        guard !value.isEmpty else { return "Branch is required" }
        guard !value.hasPrefix("-") else { return "Branch cannot begin with -" }
        guard !value.contains(where: \.isWhitespace) else { return "Branch cannot contain whitespace" }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return "Branch cannot contain control characters"
        }
        let isMalformed = invalidBranchFragments.contains { value.contains($0) }
            || value.contains { invalidBranchCharacters.contains($0) }
            || value.hasPrefix("/") || value.hasSuffix("/") || value.hasSuffix(".") || value.hasSuffix(".lock")
        return isMalformed ? "Branch is not a valid git branch name" : nil
    }

    private static let invalidBranchFragments = ["..", "//", "@{"]
    private static let invalidBranchCharacters = Set("~^:?*[\\")
}
