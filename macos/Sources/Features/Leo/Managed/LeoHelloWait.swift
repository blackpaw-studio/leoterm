import Foundation

/// Polls the daemon's hello until it answers or the setup's hello timeout
/// passes on `clock`.
struct LeoHelloWait: Sendable {
    let probe: any LeoDaemonProbing
    let clock: any LeoDaemonClock

    func version() async -> String? {
        let deadline = clock.now() + Self.nanoseconds(LeoManagedSetup.helloTimeout)
        while true {
            if case .live(let version) = await probe.probe() { return version }
            let now = clock.now()
            guard now < deadline else { return nil }
            do {
                try await clock.sleep(until: min(now + Self.nanoseconds(LeoManagedSetup.helloPollInterval), deadline))
            } catch {
                return nil
            }
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(seconds * 1_000_000_000) }
}
