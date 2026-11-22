import Foundation

/// The callbacks the app has delivered to one host session and is still
/// willing to accept a follow-up for.
///
/// The ref in a `callbackResult` is plugin-chosen text, and plugin code can
/// rewrite anything it sends (`toJSON` and all), so the app never reads
/// authority from the message. It reads it from the record it created when it
/// delivered the callback: the gesture (if any) and the slot. A ref is good
/// once, for 30 seconds, and only in the session that created it.
struct LeoPluginCallbackRegistry {
    struct Record: Equatable {
        let gesture: LeoPluginGesture?
        let slot: LeoPluginSlotID?
        let createdAt: Date
        /// False for a palette command's ref: it may open a credential
        /// prompt, but a command has no follow-up action to redeem.
        var allowsFollowUp = true
        /// Set once the ref has opened a credential prompt.
        var spentOnPrompt = false
    }

    static let capacity = 64

    private var records: [String: Record] = [:]
    private var order: [String] = []

    /// A fresh, unguessable ref for a callback about to be delivered.
    mutating func register(gesture: LeoPluginGesture?, slot: LeoPluginSlotID?, now: Date, allowsFollowUp: Bool = true) -> String {
        let ref = UUID().uuidString
        records[ref] = Record(gesture: gesture, slot: slot, createdAt: now, allowsFollowUp: allowsFollowUp)
        order.append(ref)
        while order.count > Self.capacity {
            records[order.removeFirst()] = nil
        }
        return ref
    }

    /// The record for `ref`, consumed. Nil when the ref is unknown, already
    /// used, or older than the follow-up window.
    mutating func redeem(_ ref: String, now: Date) -> Record? {
        // A command's ref is left alone: it can still open its one prompt.
        guard let record = records[ref], record.allowsFollowUp else { return nil }
        records[ref] = nil
        order.removeAll { $0 == ref }
        guard Self.isFresh(record, now: now) else { return nil }
        return record
    }

    /// Lets `ref` open one credential prompt (folder picker or Keychain
    /// dialog). True only for a fresh ref delivered with a gesture that hasn't
    /// opened one yet. Doesn't consume the ref: the handler may still return
    /// its follow-up action.
    mutating func spendCredentialPrompt(_ ref: String, now: Date) -> Bool {
        guard var record = records[ref], record.gesture != nil, !record.spentOnPrompt, Self.isFresh(record, now: now) else {
            return false
        }
        record.spentOnPrompt = true
        records[ref] = record
        return true
    }

    private static func isFresh(_ record: Record, now: Date) -> Bool {
        now.timeIntervalSince(record.createdAt) <= LeoPluginActionGate.gestureLifetime
    }

    mutating func removeAll() {
        records.removeAll()
        order.removeAll()
    }
}
