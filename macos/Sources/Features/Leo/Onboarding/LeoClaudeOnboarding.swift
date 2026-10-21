import Foundation

/// Where `claude` lives (A13). Fixed locations first, in the order the
/// installers use, then each directory of the login-shell PATH: a GUI app's
/// own PATH is too short to find a Homebrew or npm install.
struct LeoClaudeLocator {
    let home: String
    let isExecutable: (String) -> Bool
    /// The login shell's PATH (`a:b:c`), nil when unavailable. Spawns a
    /// shell, so it is only asked once the fixed locations came up empty.
    let loginPath: () async -> String?

    var fixedCandidates: [String] {
        ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    /// The fixed locations only: no login shell, so it is cheap to repeat.
    func locateFixed() -> String? {
        fixedCandidates.first(where: isExecutable)
    }

    func locate() async -> String? {
        if let fixed = locateFixed() { return fixed }
        let pathDirectories = (await loginPath() ?? "").split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        return pathDirectories.map { "\($0)/claude" }.first(where: isExecutable)
    }
}

enum LeoClaudeOnboarding {
    /// Anthropic's native installer (code.claude.com/docs/en/setup), which
    /// puts `claude` in `~/.local/bin`, then `claude` itself for login.
    static let installCommand = #"curl -fsSL https://claude.ai/install.sh | bash && "$HOME/.local/bin/claude""#
}

/// Remembers that the setup offer was shown, so it appears once.
struct LeoClaudeOnboardingStore {
    static let key = "leo.claudeOnboardingOffered"

    let defaults: UserDefaults

    var wasOffered: Bool { defaults.bool(forKey: Self.key) }
    func markOffered() { defaults.set(true, forKey: Self.key) }
}
