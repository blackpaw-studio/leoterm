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
    }

    static let capacity = 64

    private var records: [String: Record] = [:]
    private var order: [String] = []

    /// A fresh, unguessable ref for a callback about to be delivered.
    mutating func register(gesture: LeoPluginGesture?, slot: LeoPluginSlotID?, now: Date) -> String {
        let ref = UUID().uuidString
        records[ref] = Record(gesture: gesture, slot: slot, createdAt: now)
        order.append(ref)
        while order.count > Self.capacity {
            records[order.removeFirst()] = nil
        }
        return ref
    }

    /// The record for `ref`, consumed. Nil when the ref is unknown, already
    /// used, or older than the follow-up window.
    mutating func redeem(_ ref: String, now: Date) -> Record? {
        guard let record = records.removeValue(forKey: ref) else { return nil }
        order.removeAll { $0 == ref }
        guard now.timeIntervalSince(record.createdAt) <= LeoPluginActionGate.gestureLifetime else { return nil }
        return record
    }

    mutating func removeAll() {
        records.removeAll()
        order.removeAll()
    }
}
