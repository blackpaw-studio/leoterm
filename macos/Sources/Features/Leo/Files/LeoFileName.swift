import Foundation

/// Rules for a single file name crossing between the Mac and a workspace.
enum LeoFileName {
    /// One path component that is safe to open or create: non-empty, not
    /// `.`/`..`, and free of `/`, NUL and control characters (a NUL would
    /// truncate the C path; a newline or escape could forge text around it).
    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
