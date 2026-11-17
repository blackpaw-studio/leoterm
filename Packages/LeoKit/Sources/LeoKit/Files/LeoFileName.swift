import Foundation

/// Rules for a single file name crossing between the Mac and a workspace.
public enum LeoFileName {
    /// One path component that is safe to open or create: non-empty, not
    /// `.`/`..`, and free of `/`, NUL and control characters (a NUL would
    /// truncate the C path; a newline or escape could forge text around it).
    public static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// "a.txt" -> "a 2.txt"; a name without an extension (".env",
    /// "Makefile") gets the number at its end.
    public static func numbered(_ name: String, _ number: Int) -> String {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else { return "\(name) \(number)" }
        return "\((name as NSString).deletingPathExtension) \(number).\(pathExtension)"
    }
}
