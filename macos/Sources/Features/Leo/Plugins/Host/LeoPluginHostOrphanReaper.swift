import Darwin
import Foundation

/// Kills helpers left behind by a previous Leo that died hard (SIGKILL, crash).
/// A helper normally exits on socket EOF, so this is belt and braces. Run it
/// once at launch, before any helper is spawned.
///
/// A process is an orphan if its executable is exactly `helperPath` and its
/// parent is launchd (pid 1). A live helper owned by another running Leo has
/// that Leo as its parent, so it is never touched.
enum LeoPluginHostOrphanReaper {
    struct Candidate: Equatable {
        let pid: pid_t
        let parentPID: pid_t
        let path: String
    }

    /// Pure selection, so it is testable without real processes.
    static func orphans(in processes: [Candidate], helperPath: String) -> [pid_t] {
        processes.filter { $0.path == helperPath && $0.parentPID == 1 }.map(\.pid)
    }

    @discardableResult
    static func reap(helperPath: String) -> [pid_t] {
        let victims = orphans(in: snapshot(), helperPath: helperPath)
        for pid in victims { kill(pid, SIGKILL) }
        return victims
    }

    private static func snapshot() -> [Candidate] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0 else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return Candidate(pid: pid, parentPID: pid_t(info.pbi_ppid), path: String(cString: path))
        }
    }
}
