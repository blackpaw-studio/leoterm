import Darwin
import Foundation

/// The preference plists a test run leaves in the user's real
/// `~/Library/Preferences` when a test backs its defaults with a
/// `UserDefaults(suiteName:)` suite: `removePersistentDomain` empties the
/// domain but leaves the file behind (B-039). Tests inject
/// `LeoInMemoryDefaults` instead; the bundle guard fails the run if one of
/// these names appears.
enum LeoTestPreferencesListing {
    /// The real preferences directory. `getpwuid` rather than
    /// `NSHomeDirectory()`, which a sandboxed host would point at its container.
    static var directory: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// Test-suite-named plists in `directory`. Throws if it can't be read:
    /// an empty answer would let the guard pass without looking.
    static func names(in directory: URL = directory) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter(isTestSuiteName))
    }

    /// `<Leo|Ghostty…>Tests[.anything].plist`. Bare `<UUID>.plist` suites
    /// (which some tests once used) are left out: no test makes them now, and
    /// another process could.
    static func isTestSuiteName(_ fileName: String) -> Bool {
        guard fileName.hasSuffix(".plist") else { return false }
        let domain = String(fileName.dropLast(".plist".count))
        let prefix = domain.split(separator: ".", maxSplits: 1).first.map(String.init) ?? domain
        return (prefix.hasPrefix("Leo") || prefix.hasPrefix("Ghostty")) && prefix.hasSuffix("Tests")
    }
}
