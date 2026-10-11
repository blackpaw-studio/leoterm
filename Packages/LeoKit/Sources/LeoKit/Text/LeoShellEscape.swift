import Foundation

/// Backslash-escapes shell-sensitive characters, for inserting paths into a
/// live terminal buffer. Same rules as upstream Ghostty's
/// `Ghostty.Shell.escape`, which stays for upstream callers.
enum LeoShellEscape {
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func escape(_ str: String) -> String {
        escapeCharacters.reduce(str) { result, char in
            result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
    }
}
