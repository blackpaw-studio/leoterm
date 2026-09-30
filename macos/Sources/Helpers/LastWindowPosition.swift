import Cocoa

/// Manages the persistence and restoration of window positions across app launches.
class LastWindowPosition {
    static let shared = LastWindowPosition()

    static let positionKey = "NSWindowLastPosition"

    // MARK: Leo
    /// The smallest window frame worth saving or restoring (B-085): room for
    /// the agents sidebar at its minimum beside a terminal at its floor. A
    /// window that shrank below it (B-086) would otherwise be saved and come
    /// back that small on every later launch, reading as no window at all.
    static let leoMinimumSize = NSSize(
        width: LeoSidebarSplitMetrics.minimumWidth + LeoSidebarSplitMetrics.terminalFloor,
        height: 200
    )

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
    }

    /// The larger of `windowMinSize` and `leoMinimumSize` in each dimension.
    static func minimumSize(windowMinSize: NSSize) -> NSSize {
        NSSize(
            width: max(windowMinSize.width, leoMinimumSize.width),
            height: max(windowMinSize.height, leoMinimumSize.height)
        )
    }

    @discardableResult
    func save(_ window: NSWindow?) -> Bool {
        // We should only save the frame if the window is visible.
        // This avoids overriding the previously saved one
        // with the wrong one when window decorations change while creating,
        // e.g. adding a toolbar affects the window's frame.
        guard let window, window.isVisible else { return false }
        return save(frame: window.frame, minimumSize: Self.minimumSize(windowMinSize: window.minSize))
    }

    /// Saves `frame` unless it is smaller than `minimumSize` in either
    /// dimension; the last usable frame then stays saved.
    @discardableResult
    func save(frame: NSRect, minimumSize: NSSize) -> Bool {
        guard Self.isUsable(frame.size, minimumSize: minimumSize) else { return false }
        let rect = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        defaults.set(rect, forKey: Self.positionKey)
        return true
    }

    /// Restores a previously saved window frame (or parts of it) onto the given window.
    ///
    /// - Parameters:
    ///   - window: The window whose frame should be updated.
    ///   - restoreOrigin: Whether to restore the saved position. Pass `false` when the
    ///     config specifies an explicit `window-position-x`/`window-position-y`.
    ///   - restoreSize: Whether to restore the saved size. Pass `false` when the config
    ///     specifies an explicit `window-width`/`window-height`.
    /// - Returns: `true` if the frame was modified, `false` if there was nothing to restore.
    @discardableResult
    func restore(_ window: NSWindow, origin restoreOrigin: Bool = true, size restoreSize: Bool = true) -> Bool {
        guard restoreOrigin || restoreSize,
              let saved = defaults.array(forKey: Self.positionKey) as? [Double],
              let screen = window.screen ?? NSScreen.main,
              let frame = Self.restoredFrame(
                saved: saved,
                current: window.frame,
                visibleFrame: screen.visibleFrame,
                minimumSize: Self.minimumSize(windowMinSize: window.minSize),
                restoreOrigin: restoreOrigin,
                restoreSize: restoreSize
              ) else { return false }

        window.setFrame(frame, display: true)
        return true
    }

    /// The frame `restore` gives a window whose frame is `current`, from the
    /// saved `[x, y, width, height]` (or `[x, y]`), or nil when there's
    /// nothing to restore. A saved size under `minimumSize` in either
    /// dimension is not restored: the window keeps its current size.
    static func restoredFrame(
        saved: [Double],
        current: NSRect,
        visibleFrame: NSRect,
        minimumSize: NSSize,
        restoreOrigin: Bool,
        restoreSize: Bool
    ) -> NSRect? {
        guard saved.count >= 2 else { return nil }
        let savedSize = saved.count >= 4 ? NSSize(width: saved[2], height: saved[3]) : nil
        let usableSize = restoreSize ? savedSize.flatMap { isUsable($0, minimumSize: minimumSize) ? $0 : nil } : nil
        guard restoreOrigin || usableSize != nil else { return nil }

        let origin = restoreOrigin ? NSPoint(x: saved[0], y: saved[1]) : current.origin
        let size = usableSize.map {
            NSSize(width: min($0.width, visibleFrame.width), height: min($0.height, visibleFrame.height))
        } ?? current.size
        let frame = NSRect(origin: origin, size: size)

        // If the new frame is not constrained to the visible screen,
        // we need to shift it a little bit before AppKit does this for us,
        // so that we can save the correct size beforehand.
        // This fixes restoration while running UI tests,
        // where config is modified without switching apps,
        // which will not trigger `windowDidBecomeMain`.
        guard restoreOrigin, !visibleFrame.contains(frame) else { return frame }
        return NSRect(
            x: max(visibleFrame.minX, min(visibleFrame.maxX - frame.width, frame.origin.x)),
            y: max(visibleFrame.minY, min(visibleFrame.maxY - frame.height, frame.origin.y)),
            width: frame.width,
            height: frame.height
        )
    }

    private static func isUsable(_ size: NSSize, minimumSize: NSSize) -> Bool {
        size.width >= minimumSize.width && size.height >= minimumSize.height
    }
}
