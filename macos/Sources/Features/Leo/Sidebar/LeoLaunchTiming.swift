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

    @MainActor static func mark(_ milestone: String, _ detail: String = "") {
        guard logged.insert(milestone).inserted else { return }
        let ms = Int((Date().timeIntervalSince1970 - processStart) * 1000)
        logger.log("\(milestone, privacy: .public) +\(ms)ms \(detail, privacy: .public)")
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
