enum LeoPortForwardError: Error, Equatable, Sendable {
    /// The local port is taken (ssh exits 255 on a forward it cannot bind).
    case portBusy
    case noFreePort
    case failed(String)
}
