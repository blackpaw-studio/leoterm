import Foundation
import LeoKit

/// Every machine's port forwards for agent browsers, handed to each
/// browser as its `LeoBrowserURLMapping`. This Mac maps nothing. A remote
/// machine gets a fresh `LeoPortForwards` each time it connects (on that
/// connection's ssh), and every forward closes when it drops. A browser's
/// mapping always reaches its machine's current forwards, so a browser
/// outlives a reconnect.
@MainActor final class LeoMachinePortForwards {
    /// `host`'s forwards for a connection that just came up; nil when it
    /// can't forward (its configuration is gone).
    typealias MakeForwards = @MainActor (LeoHostID) -> LeoPortForwards?

    private let makeForwards: MakeForwards
    private var current: [LeoHostID: LeoPortForwards] = [:]

    init(makeForwards: @escaping MakeForwards) {
        self.makeForwards = makeForwards
    }

    /// `host` connected: its browsers forward over this connection from now
    /// on. A connection it still had is dropped first.
    func connected(_ host: LeoHostID) {
        guard host != .local else { return }
        current.removeValue(forKey: host)?.releaseAll()
        current[host] = makeForwards(host)
    }

    /// `host` dropped (or went): loopback URLs fail from now until it
    /// connects again, and every forward on it closes in the returned task.
    @discardableResult
    func disconnected(_ host: LeoHostID) -> Task<Void, Never>? {
        current.removeValue(forKey: host)?.releaseAll()
    }

    /// The app is quitting: every machine's forwards close in the returned
    /// task, which never needs the main actor -- the quit blocks it while
    /// it waits.
    func shutdown() -> Task<Void, Never> {
        let closing = current.values.map { $0.releaseAll() }
        current = [:]
        return Task.detached {
            for task in closing { await task.value }
        }
    }

    /// The URL mapping for `key`'s browser.
    func mapping(for key: LeoAgentBrowserKey) -> any LeoBrowserURLMapping {
        guard key.host != .local else { return LeoIdentityURLMapping() }
        return LeoForwardedURLMapping(key: key, owner: self)
    }

    /// `key`'s browser closed: each forward it held closes once no other
    /// browser holds it.
    func release(_ key: LeoAgentBrowserKey) async {
        await current[key.host]?.release(browser: key.agent)
    }

    fileprivate func forwards(for host: LeoHostID) -> LeoPortForwards? { current[host] }
}

/// One remote browser's view of its machine's forwards.
@MainActor private final class LeoForwardedURLMapping: LeoBrowserURLMapping {
    private let key: LeoAgentBrowserKey
    private weak var owner: LeoMachinePortForwards?
    /// Local port → the remote port it was handed out for, kept across
    /// reconnects. A page loaded over a dropped connection still names the
    /// remote address it came from, so its address bar, Copy URL, reopen
    /// and Open in Default Browser never take its old local port (another
    /// one when the remote's was busy here) for a remote one.
    private var remotePorts: [Int: Int] = [:]

    init(key: LeoAgentBrowserKey, owner: LeoMachinePortForwards) {
        self.key = key
        self.owner = owner
    }

    func toLocal(_ url: URL) async throws -> URL {
        guard let port = LeoPortForwardPlanner.loopbackPort(of: url) else { return url }
        guard let forwards = owner?.forwards(for: key.host) else {
            throw LeoBrowserError(.navigationFailed, "\(key.host.displayName) is not connected, so port \(port) on it can't be reached")
        }
        do {
            let local = try await forwards.acquire(url, browser: key.agent)
            if let localPort = LeoPortForwardPlanner.loopbackPort(of: local) { remotePorts[localPort] = port }
            return local
        } catch let error as LeoPortForwardError {
            throw LeoBrowserError(.navigationFailed, "Could not forward port \(port) from \(key.host.displayName): \(Self.describe(error))")
        }
    }

    /// Only ports this browser was handed map back. Any other loopback
    /// address is the remote's own, never another browser's forward.
    func toRemote(_ url: URL) -> URL {
        LeoPortForwardPlanner.remap(url, using: remotePorts)
    }

    private static func describe(_ error: LeoPortForwardError) -> String {
        switch error {
        case .portBusy, .ipv6Unavailable: "every local port tried was busy"
        case .noFreePort: "no free local port"
        case .failed(let message): message.isEmpty ? "ssh failed" : message
        }
    }
}
