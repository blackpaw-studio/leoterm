import Foundation

/// Which machine the spawn sheet starts on.
public enum LeoSpawnMachineDefault {
    /// The first selectable of the context machine ("New Agent Here", a
    /// board, a row), then the last machine used to spawn, else This Mac. A
    /// machine missing from `statuses` (removed since) is not selectable,
    /// except This Mac, which always exists.
    public static func resolve(
        context: LeoHostID?, lastUsed: LeoHostID?, statuses: [LeoHostID: LeoMachineStatus]
    ) -> LeoHostID {
        [context, lastUsed].compactMap { $0 }.first { isSelectable($0, statuses) } ?? .local
    }

    private static func isSelectable(_ host: LeoHostID, _ statuses: [LeoHostID: LeoMachineStatus]) -> Bool {
        statuses[host]?.isSelectable ?? (host == .local)
    }
}
