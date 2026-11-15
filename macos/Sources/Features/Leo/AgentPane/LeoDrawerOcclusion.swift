/// Whether a drawer terminal is on screen. Drawer surfaces are in no
/// controller's surface tree, so the window's own occlusion sync never
/// reaches them: the drawer drives libghostty's occlusion from this.
enum LeoDrawerOcclusion {
    /// On screen only when its view is mounted in the pane, the window is
    /// visible, the drawer is open and the Terminal tab is the selected one.
    static func isVisible(isMounted: Bool, windowVisible: Bool, expanded: Bool, selectedIsTerminal: Bool) -> Bool {
        isMounted && windowVisible && expanded && selectedIsTerminal
    }
}
