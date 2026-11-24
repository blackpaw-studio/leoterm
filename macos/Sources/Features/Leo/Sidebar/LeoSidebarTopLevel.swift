import LeoKit

/// The sidebar list's top-level blocks, in the user's section order
/// (B-438): every machine group together as the one Agents section, this
/// window's Terminals, and the plugin sections. By default that's the
/// machines, then Terminals, then the plugin sections. Plugin sections
/// are app-level, so each appears once here and never inside a machine
/// group.
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

        /// The section it moves with: every machine is the one Agents section.
        var orderKey: String {
            switch self {
            case .machine: LeoSidebarSectionOrder.agents
            case .terminals: LeoSidebarSectionOrder.terminals
            case .pluginSection(let id): LeoSidebarSectionOrder.pluginKey(id)
            }
        }
    }

    /// The blocks in `order` (see `LeoSidebarSectionOrder.arrange`): a
    /// section with nothing to show is left out, and one `order` doesn't
    /// name yet goes at the bottom. The machines keep their own order.
    static func blocks(machines: [LeoHostID], showsTerminals: Bool, pluginSectionIDs: [String], order: [String] = []) -> [Block] {
        let plugins = Dictionary(pluginSectionIDs.map { (LeoSidebarSectionOrder.pluginKey($0), Block.pluginSection(id: $0)) }) { first, _ in first }
        let live = (machines.isEmpty ? [] : [LeoSidebarSectionOrder.agents])
            + (showsTerminals ? [LeoSidebarSectionOrder.terminals] : [])
            + pluginSectionIDs.map(LeoSidebarSectionOrder.pluginKey)
        return LeoSidebarSectionOrder.arrange(saved: order, live: live).flatMap { key -> [Block] in
            switch key {
            case LeoSidebarSectionOrder.agents: machines.map(Block.machine)
            case LeoSidebarSectionOrder.terminals: [.terminals]
            default: plugins[key].map { [$0] } ?? []
            }
        }
    }

    /// The sections `blocks` shows, top to bottom: what Move Up, Move Down
    /// and a drop move among.
    static func sectionKeys(of blocks: [Block]) -> [String] {
        var seen: Set<String> = []
        return blocks.map(\.orderKey).filter { seen.insert($0).inserted }
    }

    /// The table row `key`'s section starts at: the rows the sections
    /// above it take.
    static func rowOffset(of key: String, in sections: [String], rowCounts: [String: Int]) -> Int {
        sections.prefix { $0 != key }.reduce(0) { $0 + rowCounts[$1, default: 0] }
    }
}
