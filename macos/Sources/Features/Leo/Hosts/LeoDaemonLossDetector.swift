import Foundation
import LeoKit

/// Reads each machine's feed for what `LeoMachineRegistry` can't see on
/// its own: a daemon that stopped answering while its connection (This
/// Mac's socket, or a tunnel still running) stayed up, and a daemon that
/// answered again. Only transitions count, so a dropped feed re-emitting
/// its snapshot never reports the same loss twice.
struct LeoDaemonLossDetector {
    enum Signal: Equatable {
        /// The feed's live connection, or a Retry's fresh one, dropped.
        case stoppedAnswering(reason: String)
        /// The feed's list landed.
        case answered
    }

    private var last: [LeoHostID: LeoConnectivity] = [:]

    mutating func observe(_ connectivity: LeoConnectivity, for host: LeoHostID) -> Signal? {
        let previous = last.updateValue(connectivity, forKey: host)
        switch connectivity {
        case .disconnected(let reason, isRetrying: false) where !(previous.map(Self.isLost) ?? false):
            return .stoppedAnswering(reason: reason)
        case .connected where previous != .connected:
            return .answered
        default:
            return nil
        }
    }

    private static func isLost(_ connectivity: LeoConnectivity) -> Bool {
        if case .disconnected(_, isRetrying: false) = connectivity { return true }
        return false
    }
}
