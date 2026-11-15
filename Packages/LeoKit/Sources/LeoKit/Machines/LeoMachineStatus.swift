import Foundation

/// Where a machine's connection stands.
public enum LeoMachineStatus: Equatable, Sendable {
    case connecting
    case connected
    case failed(String)
    /// Turned off in settings; never connected.
    case disabled

    /// Only a connected machine can take a spawn.
    public var isSelectable: Bool {
        if case .connected = self { return true }
        return false
    }
}
