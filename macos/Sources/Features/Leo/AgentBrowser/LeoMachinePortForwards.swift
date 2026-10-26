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
        if let previous = current.removeValue(forKey: host) { Task { await previous.releaseAll() } }
        current[host] = makeForwards(host)
    }

    /// `host` dropped (or went): loopback URLs fail from now until it
    /// connects again, and every forward on it closes in the returned task.
    @discardableResult
    func disconnected(_ host: LeoHostID) -> Task<Void, Never>? {
        guard let gone = current.removeValue(forKey: host) else { return nil }
        return Task { await gone.releaseAll() }
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
            return try await forwards.acquire(url, browser: key.agent)
        } catch let error as LeoPortForwardError {
            throw LeoBrowserError(.navigationFailed, "Could not forward port \(port) from \(key.host.displayName): \(Self.describe(error))")
        }
    }

    func toRemote(_ url: URL) -> URL {
        owner?.forwards(for: key.host)?.toRemote(url) ?? url
    }

    private static func describe(_ error: LeoPortForwardError) -> String {
        switch error {
        case .portBusy, .ipv6Unavailable: "every local port tried was busy"
        case .noFreePort: "no free local port"
        case .failed(let message): message.isEmpty ? "ssh failed" : message
        }
    }
}
