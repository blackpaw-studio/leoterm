import Darwin
import Foundation
import LeoKit

/// Reads a child's CPU time and memory footprint with `proc_pid_rusage`.
enum LeoPluginProcessUsage {
    static func read(pid: pid_t) -> LeoPluginUsage? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = info.ri_user_time + info.ri_system_time
        return LeoPluginUsage(
            cpuSeconds: LeoPluginUsage.seconds(fromMachTicks: ticks, numer: timebase.numer, denom: timebase.denom),
            footprintBytes: info.ri_phys_footprint)
    }
}
