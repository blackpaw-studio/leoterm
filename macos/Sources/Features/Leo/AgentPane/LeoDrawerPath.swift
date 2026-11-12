import Foundation

/// The path the Terminal tab's collapsed strip shows: the shell's own
/// directory (OSC 7) once it has reported one, else the agent's workspace,
/// shortened the way the Status plugin shortens its paths
/// (`~/.leo/agents/leoterm` → `~/.l/a/leoterm`). Pure.
enum LeoDrawerPath {
    static func summary(pwd: String?, workspace: String?, home: String?) -> String? {
        guard let path = plainPath(pwd) ?? plainPath(workspace) else { return nil }
        return shorten(tildeAbbreviated(path, home: home))
    }

    /// A `file://host/path` URL (as OSC 7 sends it) becomes its path; a plain
    /// path is kept. Empty means unknown.
    static func plainPath(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.hasPrefix("file://") else { return value }
        guard let path = URL(string: value)?.path, !path.isEmpty else { return nil }
        return path
    }

    /// Home becomes `~`, only on a whole-component match and only when a home is known.
    private static func tildeAbbreviated(_ path: String, home: String?) -> String {
        guard let home, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Middle components keep their first character (and a leading dot); the
    /// first `~` and the last component stay whole. Matches `shortenPath` in
    /// `plugins/status/src/format.ts`.
    static func shorten(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let head = path.hasPrefix("/") ? "/" : ""
        let last = parts.count - 1
        let body = parts.enumerated().map { index, part -> String in
            if index == last || (index == 0 && part == "~") { return part }
            return String(part.prefix(part.hasPrefix(".") ? 2 : 1))
        }
        return head + body.joined(separator: "/")
    }
}
