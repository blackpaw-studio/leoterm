import Foundation

/// Whether launchd has the app's job loaded, from `launchctl print`: a
/// read-only check for B10, since SMAppService reports registration, not
/// what launchd runs. A daemon answering while this says "not loaded" was
/// started outside the job.
struct LeoAppJob: Sendable {
    static let launchctl = "/bin/launchctl"
    static let timeout: TimeInterval = 5
    /// `launchctl print` for a service launchd doesn't know.
    static let notFoundStatus: Int32 = 113

    let runner: any LeoProcessRunning
    let label: String
    var uid: uid_t = getuid()

    /// nil when it can't say (launchctl missing, odd exit): never grounds to accuse a daemon.
    func isLoaded() async -> Bool? {
        guard let result = try? await runner.run(
            executable: Self.launchctl, arguments: ["print", "gui/\(uid)/\(label)"], timeout: Self.timeout
        ) else { return nil }
        switch result.status {
        case 0: return true
        case Self.notFoundStatus: return false
        default: return nil
        }
    }
}
