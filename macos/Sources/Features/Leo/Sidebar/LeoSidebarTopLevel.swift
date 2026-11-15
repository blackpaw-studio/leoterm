import LeoKit

/// The sidebar list's top-level blocks, in order: every machine group, then
/// this window's Terminals, then the plugin sections. Plugin sections are
/// app-level, so each appears once here and never inside a machine group.
enum LeoSidebarTopLevel {
    enum Block: Equatable, Identifiable {
        case machine(LeoHostID)
        case terminals
        case pluginSection(id: String)

        var id: String {
            switch self {
            case .machine(let host): "machine:\(host)"
            case .terminals: "terminals"
            case .pluginSection(let id): "plugin:\(id)"
            }
        }
    }

    static func blocks(machines: [LeoHostID], showsTerminals: Bool, pluginSectionIDs: [String]) -> [Block] {
        machines.map(Block.machine)
            + (showsTerminals ? [.terminals] : [])
            + pluginSectionIDs.map(Block.pluginSection)
    }
}
