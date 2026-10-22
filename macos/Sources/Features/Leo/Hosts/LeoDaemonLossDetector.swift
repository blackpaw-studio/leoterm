import Foundation
import LeoKit

/// Reads each machine's feed for what `LeoMachineRegistry` can't see on
/// its own: a daemon that stopped answering while its connection (This
/// Mac's socket, or a tunnel still running) stayed up, and a daemon that
/// answered again.
///
/// Every drop mints a new snapshot generation, so a dropped snapshot with
/// a generation not seen dropped before is a new loss: a live connection's,
/// or a Retry's (This Mac's Retry connects at once, so its feed can drop
/// again without ever showing it was retrying). A re-emit keeps its
/// generation and is never reported twice.
struct LeoDaemonLossDetector {
    enum Signal: Equatable {
        /// The feed's live connection, or a Retry's fresh one, dropped.
        case stoppedAnswering(reason: String)
        /// The feed's list landed.
        case answered
    }

    private var last: [LeoHostID: (connectivity: LeoConnectivity, generation: Int)] = [:]

    mutating func observe(_ snapshot: LeoSidebarSnapshot, for host: LeoHostID) -> Signal? {
        let previous = last.updateValue((snapshot.connectivity, snapshot.generation), forKey: host)
        switch snapshot.connectivity {
        case .disconnected(let reason, isRetrying: false):
            let isReemit = previous.map { Self.isLost($0.connectivity) && $0.generation == snapshot.generation } ?? false
            return isReemit ? nil : .stoppedAnswering(reason: reason)
        case .connected where previous?.connectivity != .connected:
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
