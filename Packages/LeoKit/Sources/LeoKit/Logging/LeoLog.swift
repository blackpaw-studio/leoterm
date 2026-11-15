import Foundation
import OSLog

/// LeoKit's unified-logging identity. The subsystem defaults to the Mac
/// app's; another host app (the iOS app) sets its own once at launch,
/// before any LeoKit logging happens.
public enum LeoLog {
    public static let defaultSubsystem = "studio.blackpaw.leo.macos"
    public static let category = "leo"

    private static let storage = OSAllocatedUnfairLock(initialState: defaultSubsystem)

    public static var subsystem: String {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// A logger in the current subsystem. Cheap: call it at the log site.
    public static func logger(category: String = category) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
