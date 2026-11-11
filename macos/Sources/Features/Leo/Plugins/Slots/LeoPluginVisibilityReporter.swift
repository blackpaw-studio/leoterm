import LeoKit
import SwiftUI

/// Tells a slot surface when one on-screen thing of a slot (a section's rows,
/// an accessory chip, a pane) appears and disappears. The surface counts these
/// per slot, so every `true` it is given must be matched by one `false`: this
/// sends `true` only on the way up and `false` only on the way down, and
/// releases a still-visible report when it goes away (the view was removed or
/// its window closed without a disappear). A thing is visible while it has
/// appeared and is active (a section's rows only while it is expanded).
@MainActor final class LeoPluginVisibilityReporter {
    let key: LeoPluginSlotKey
    private let surface: any LeoPluginSlotSurface
    private var hasAppeared = false
    private var isActive: Bool
    private var isReported = false

    init(key: LeoPluginSlotKey, surface: any LeoPluginSlotSurface, isActive: Bool = true) {
        self.key = key
        self.surface = surface
        self.isActive = isActive
    }

    func setAppeared(_ appeared: Bool) {
        hasAppeared = appeared
        report()
    }

    func setActive(_ active: Bool) {
        isActive = active
        report()
    }

    private func report() {
        let visible = hasAppeared && isActive
        guard visible != isReported else { return }
        isReported = visible
        surface.setVisible(key, visible)
    }

    deinit {
        guard isReported else { return }
        let (surface, key) = (surface, key)
        MainActor.assumeIsolated { surface.setVisible(key, false) }
    }
}

private struct LeoPluginReportsVisibility: ViewModifier {
    let surface: (any LeoPluginSlotSurface)?
    let key: LeoPluginSlotKey?
    let isActive: Bool
    @State private var reporter: LeoPluginVisibilityReporter?

    func body(content: Content) -> some View {
        content
            .onAppear { bind()?.setAppeared(true) }
            .onDisappear { reporter?.setAppeared(false) }
            .onChange(of: isActive) { active in reporter?.setActive(active) }
    }

    /// The reporter for the current key; a new key releases the old report first.
    private func bind() -> LeoPluginVisibilityReporter? {
        guard let surface, let key else { return nil }
        if let reporter, reporter.key == key { reporter.setActive(isActive); return reporter }
        reporter?.setAppeared(false)
        let next = LeoPluginVisibilityReporter(key: key, surface: surface, isActive: isActive)
        reporter = next
        return next
    }
}

extension View {
    /// Reports this view's on-screen state to `surface` for `key` (a no-op
    /// without a surface or key), only while `isActive`.
    func leoPluginReportsVisibility(to surface: (any LeoPluginSlotSurface)?, key: LeoPluginSlotKey?, isActive: Bool = true) -> some View {
        modifier(LeoPluginReportsVisibility(surface: surface, key: key, isActive: isActive))
    }
}
