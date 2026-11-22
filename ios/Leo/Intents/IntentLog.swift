import Foundation
import os

/// Records which process ran an intent's `perform`, so the device check can
/// tell the Leo app from the Controls extension:
/// `log stream --predicate 'subsystem == "studio.blackpaw.leo" AND category == "intents"'`.
/// Shared by the app and the Controls extension.
enum IntentLog {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo", category: "intents")

    static func performed(_ intent: String) {
        let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
        let process = ProcessInfo.processInfo.processName
        logger.notice("\(intent, privacy: .public) perform in \(process, privacy: .public) (\(isExtension ? "extension" : "app", privacy: .public))")
    }
}
