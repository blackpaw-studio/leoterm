import Foundation

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
    static func spawn(template: String?, repo: String, name: String?, pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard let template, !template.isEmpty else { return "Template is required" }
        guard repo.isEmpty || pathExists(repo) else { return "Choose an existing repository" }
        return name.flatMap { Self.name($0) }
    }

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
