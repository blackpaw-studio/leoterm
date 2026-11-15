import Foundation

/// Pure containment check for the app to run on a bundle path after it has
/// resolved symlinks (`resolvingSymlinksInPath()`), before reading the file.
public enum LeoPluginPathContainment {
    /// Whether `resolved` is a strict descendant of `folder`. Both are compared
    /// as standardized file URL path components (so `.`/`..` and a trailing
    /// slash don't matter, and `/p/plugin-evil` is not inside `/p/plugin`).
    public static func isContained(resolved: URL, in folder: URL) -> Bool {
        guard resolved.isFileURL, folder.isFileURL else { return false }
        let file = resolved.standardizedFileURL.pathComponents
        let root = folder.standardizedFileURL.pathComponents
        return file.count > root.count && file.starts(with: root)
    }
}
