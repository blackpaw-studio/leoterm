enum LeoPortForwardError: Error, Equatable, Sendable {
    /// The local port is taken (ssh exits 255 on a forward it cannot bind).
    case portBusy
    case noFreePort
    /// Internal to the runners: the IPv6 loopback listener could not bind, so
    /// the forward falls back to IPv4-only. Never reaches the manager.
    case ipv6Unavailable
    case failed(String)
}
