import Foundation

public enum LeoPluginKeychainGateError: Error, Equatable, Sendable {
    /// Reading or changing the interaction flag failed with this OSStatus.
    case interactionStatus(Int32)
}

/// The one door every plugin-system Keychain call goes through (`leo.secrets`
/// and account credentials). A no-UI call runs alone: it turns the
/// process-wide "Keychain may show UI" flag off for its duration and puts back
/// whatever it was before, so no other call ever runs while it is off and
/// another plugin's prompt is never suppressed. Calls that allow UI never touch
/// the flag, so they only exclude no-UI calls, not each other: a read waiting
/// on the Keychain dialog doesn't stall `leo.secrets` on the main thread.
///
/// The flag itself is injected: on the Mac it is
/// `SecKeychain{Get,Set}UserInteractionAllowed`, and this gate is the only
/// code that touches it. Platform-neutral, so tests drive it with a fake.
public final class LeoPluginKeychainGate: @unchecked Sendable {
    public struct Interaction: Sendable {
        let isAllowed: @Sendable () throws -> Bool
        let setAllowed: @Sendable (Bool) throws -> Void

        public init(isAllowed: @escaping @Sendable () throws -> Bool, setAllowed: @escaping @Sendable (Bool) throws -> Void) {
            self.isAllowed = isAllowed
            self.setAllowed = setAllowed
        }
    }

    private let interaction: Interaction
    private let restoreFailed: @Sendable (any Error) -> Void
    private let lock: UnsafeMutablePointer<pthread_rwlock_t> = {
        let lock = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        pthread_rwlock_init(lock, nil)
        return lock
    }()

    /// `restoreFailed` hears about a flag that couldn't be put back (logged by the app).
    public init(interaction: Interaction, restoreFailed: @escaping @Sendable (any Error) -> Void = { _ in }) {
        self.interaction = interaction
        self.restoreFailed = restoreFailed
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    /// Runs `body`. With `allowUI == false` it runs alone with the flag off;
    /// if the flag can't be read or cleared, `body` doesn't run (it could show UI).
    public func run<T>(allowUI: Bool, _ body: () throws -> T) throws -> T {
        guard !allowUI else {
            pthread_rwlock_rdlock(lock)
            defer { pthread_rwlock_unlock(lock) }
            return try body()
        }
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        let previous = try interaction.isAllowed()
        try interaction.setAllowed(false)
        defer {
            do { try interaction.setAllowed(previous) } catch { restoreFailed(error) }
        }
        return try body()
    }
}
