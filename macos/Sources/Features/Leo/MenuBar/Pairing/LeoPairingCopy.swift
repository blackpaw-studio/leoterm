import Foundation

/// The wording of the Pair a Device panel's states, kept apart from the layout so it is tested.
enum LeoPairingCopy {
    static let enablingTitle = "Turning on web access…"
    static let enablingDetail = "Waiting for busy agents to finish…"

    /// Shown before web access is turned on. leo has no way to report the bind before enabling,
    /// so it says plainly that the daemon's configured address is used; the actual one follows.
    static let enableExplanation = """
        Turning on web access lets devices on your network reach the Leo daemon on this Mac, \
        using the bind address in its configuration. Busy agents finish their work first, \
        then the daemon restarts.
        """

    /// Shown once it is on, with what leo reports.
    static func webEnabledNotice(bind: String, port: Int) -> String {
        let host = bind.contains(":") ? "[\(bind)]" : bind
        return "Web access is on at \(host):\(port)."
    }
}
