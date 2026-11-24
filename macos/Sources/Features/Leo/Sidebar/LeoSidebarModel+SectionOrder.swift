/// B-438: moving the sidebar's top-level sections. One app-wide order, kept
/// in the sidebar preferences, so it holds across windows and relaunches.
/// `visible` is what the list shows, top to bottom.
extension LeoSidebarModel {
    /// Moves `key` past the shown section above or below it.
    func moveSection(_ key: String, _ direction: LeoSidebarSectionOrder.Direction, visible: [String]) {
        saveSectionOrder(LeoSidebarSectionOrder.moving(
            key, direction, visible: visible, saved: preferences.sectionOrder, known: knownSectionKeys
        ))
    }

    /// Moves `key` to `target`'s slot: one section header dropped on another.
    func moveSection(_ key: String, onto target: String, visible: [String]) {
        saveSectionOrder(LeoSidebarSectionOrder.moving(
            key, onto: target, visible: visible, saved: preferences.sectionOrder, known: knownSectionKeys
        ))
    }

    /// Whether a window's Terminals list above the agents.
    var listsTerminalsFirst: Bool {
        LeoSidebarSectionOrder.arrange(saved: preferences.sectionOrder, live: LeoSidebarSectionOrder.builtIns).first
            == LeoSidebarSectionOrder.terminals
    }

    /// Every section the order keeps a slot for: the built-ins, every
    /// installed plugin's sections (listed, turned off or hidden), and
    /// every saved one, so an uninstalled plugin's comes back to its slot.
    private var knownSectionKeys: [String] {
        LeoSidebarSectionOrder.builtIns
            + (pluginSections?.allEntryIDs ?? []).map(LeoSidebarSectionOrder.pluginKey)
            + preferences.sectionOrder
    }

    private func saveSectionOrder(_ order: [String]?) {
        guard let order else { return }
        update(preferences.with(sectionOrder: order))
    }
}
