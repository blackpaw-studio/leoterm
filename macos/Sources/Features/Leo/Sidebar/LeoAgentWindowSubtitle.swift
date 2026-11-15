import Foundation
import LeoKit

/// The agent window's subtitle: `<cwd, ~-abbreviated> · <harness>`. Pure.
enum LeoAgentWindowSubtitle {
    private static let separator = " · "

    /// The local host collapses `localHome`. A remote host collapses
    /// `/Users/<user>` and `/home/<user>` only when its login is known; an
    /// unknown login shows the full path, never the laptop's home.
    static func text(workspace: String?, harness: String?, host: LeoHostID, localHome: String, remoteUser: String?) -> String {
        let homes: [String] =
            switch host {
            case .local: [localHome]
            case .remote: remoteUser.map { ["/Users/\($0)", "/home/\($0)"] } ?? []
            }
        let parts = [workspace.flatMap { $0.isEmpty ? nil : abbreviate($0, homes: homes) }, harness.flatMap { $0.isEmpty ? nil : $0 }]
        return parts.compactMap { $0 }.joined(separator: separator)
    }

    private static func abbreviate(_ path: String, homes: [String]) -> String {
        for home in homes where !home.isEmpty {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }
}
