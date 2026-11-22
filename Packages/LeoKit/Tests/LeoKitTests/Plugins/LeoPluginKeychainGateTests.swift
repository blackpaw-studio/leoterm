import Foundation
import Testing

@testable import LeoKit

/// Stands in for the process-wide "may the Keychain show UI" flag.
private final class FakeInteraction: @unchecked Sendable {
    private let lock = NSLock()
    private var _allowed: Bool
    private var _sets: [Bool] = []
    var failRead = false
    var failSet: Bool?

    init(allowed: Bool) { _allowed = allowed }

    var allowed: Bool { lock.withLock { _allowed } }
    var sets: [Bool] { lock.withLock { _sets } }

    var interaction: LeoPluginKeychainGate.Interaction {
        LeoPluginKeychainGate.Interaction(
            isAllowed: { [self] in
                if failRead { throw LeoPluginKeychainGateError.interactionStatus(-1) }
                return allowed
            },
            setAllowed: { [self] value in
                if failSet == value { throw LeoPluginKeychainGateError.interactionStatus(-2) }
                lock.withLock {
                    _sets.append(value)
                    _allowed = value
                }
            })
    }
}

private struct Boom: Error {}

struct LeoPluginKeychainGateTests {
    @Test(arguments: [true, false])
    func aNoUIRunDisablesInteractionThenRestoresThePreviousValue(previous: Bool) throws {
        let fake = FakeInteraction(allowed: previous)
        let gate = LeoPluginKeychainGate(interaction: fake.interaction)
        let during = try gate.run(allowUI: false) { fake.allowed }
        #expect(during == false)
        #expect(fake.allowed == previous)
    }

    @Test func theFlagIsRestoredWhenTheBodyThrows() {
        let fake = FakeInteraction(allowed: true)
        let gate = LeoPluginKeychainGate(interaction: fake.interaction)
        #expect(throws: Boom.self) { try gate.run(allowUI: false) { throw Boom() } }
        #expect(fake.allowed)
    }

    @Test func aRunWithUILeavesTheFlagAlone() throws {
        let fake = FakeInteraction(allowed: true)
        try LeoPluginKeychainGate(interaction: fake.interaction).run(allowUI: true) {}
        #expect(fake.sets.isEmpty)
    }

    @Test func aFlagThatCantBeReadOrClearedSkipsTheRead() {
        let unreadable = FakeInteraction(allowed: true)
        unreadable.failRead = true
        let uncleared = FakeInteraction(allowed: true)
        uncleared.failSet = false
        for fake in [unreadable, uncleared] {
            var ran = false
            #expect(throws: LeoPluginKeychainGateError.self) {
                try LeoPluginKeychainGate(interaction: fake.interaction).run(allowUI: false) { ran = true }
            }
            #expect(!ran)
        }
    }

    @Test func aFailedRestoreIsReported() throws {
        let fake = FakeInteraction(allowed: true)
        fake.failSet = true
        let reported = FakeInteraction(allowed: false)  // reused as a thread-safe flag
        let gate = LeoPluginKeychainGate(interaction: fake.interaction) { _ in try? reported.interaction.setAllowed(true) }
        try gate.run(allowUI: false) {}
        #expect(reported.allowed)
    }

    @Test func aNoUIRunNeverOverlapsAnyOtherRun() {
        let fake = FakeInteraction(allowed: true)
        let gate = LeoPluginKeychainGate(interaction: fake.interaction)
        let lock = NSLock()
        nonisolated(unsafe) var active = 0
        nonisolated(unsafe) var sharedWithNoUI = false
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let allowUI = !index.isMultiple(of: 3)
            try? gate.run(allowUI: allowUI) {
                lock.withLock { active += 1 }
                usleep(200)
                lock.withLock {
                    if !allowUI, active != 1 { sharedWithNoUI = true }
                    active -= 1
                }
            }
        }
        #expect(!sharedWithNoUI)
        #expect(fake.allowed)
    }

    /// A read waiting on the Keychain dialog must not stall `leo.secrets` on the main thread.
    @Test func runsWithUIDontWaitForEachOther() {
        let gate = LeoPluginKeychainGate(interaction: FakeInteraction(allowed: true).interaction)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? gate.run(allowUI: true) {
                entered.signal()
                release.wait()
            }
        }
        entered.wait()
        let second = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? gate.run(allowUI: true) { second.signal() }
        }
        #expect(second.wait(timeout: .now() + 5) == .success)
        release.signal()
    }
}
