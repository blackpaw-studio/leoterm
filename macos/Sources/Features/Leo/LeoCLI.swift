import Foundation

/// Shared constants for the `leo` CLI.
///
/// Using an enum (not a struct or class) prevents accidental instantiation —
/// it's a pure namespace for static members.
enum LeoCLI {
    /// Absolute path to the `leo` executable.
    ///
    /// A GUI app's `$PATH` does not include `~/.local/bin`, so bare `leo`
    /// fails with "env: leo: No such file or directory". All production sites
    /// that launch or shell out to `leo` must use this constant, not a bare
    /// name or relative path. The value is expanded at launch time so the
    /// tilde resolves to the real home directory of the running user.
    static let executablePath = NSString(string: "~/.local/bin/leo").expandingTildeInPath
}
