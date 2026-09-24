#if DEBUG
import Darwin
import Foundation
import OSLog

/// DEBUG-only cold-start milestones (B-012): each is logged once, as
/// milliseconds since the process started, under category `LaunchTiming`.
/// Read with `log show --predicate 'category == "LaunchTiming"'`.
enum LeoLaunchTiming {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "LaunchTiming")
    @MainActor private static var logged: Set<String> = []

    /// `detail` is only built the first time `milestone` is marked.
    @MainActor static func mark(_ milestone: String, _ detail: @autoclosure () -> String = "") {
        guard logged.insert(milestone).inserted else { return }
        let ms = Int((Date().timeIntervalSince1970 - processStart) * 1000)
        let text = detail()
        logger.log("\(milestone, privacy: .public) +\(ms)ms \(text, privacy: .public)")
    }

    /// Marks `milestone` on the first `name` notification, then stops observing.
    @MainActor static func markOnFirst(_ name: Notification.Name, as milestone: String, center: NotificationCenter = .default) {
        let box = ObserverBox()
        box.token = center.addObserver(forName: name, object: nil, queue: .main) { [box] _ in
            MainActor.assumeIsolated {
                mark(milestone)
                guard let token = box.token else { return }
                center.removeObserver(token)
                box.token = nil
            }
        }
    }

    private final class ObserverBox: @unchecked Sendable {
        /// Only touched on the main queue.
        var token: NSObjectProtocol?
    }

    private static let processStart: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let start = info.kp_proc.p_un.__p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }()
}
#endif
