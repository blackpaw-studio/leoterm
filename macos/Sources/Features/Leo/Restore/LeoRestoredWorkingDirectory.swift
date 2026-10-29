import Foundation

/// B-332: the directory a terminal restored at launch starts its shell in:
/// the one it was in at quit, or home once that is gone (or no longer a
/// directory). A shell that never reported where it was (`nil`: no OSC 7)
/// starts where a new one does, in Ghostty's `working-directory`.
enum LeoRestoredWorkingDirectory {
    static func resolve(
        pwd: String?,
        isDirectory: (String) -> Bool = isDirectory,
        home: String = NSHomeDirectory()
    ) -> String? {
        guard let pwd, !pwd.isEmpty else { return nil }
        return isDirectory(pwd) ? pwd : home
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
