import Foundation

/// The managed daemon's state for the Settings window. The app's managed
/// startup owns the state and the actions; this carries both across, so
/// Settings can show the state and offer its actions without reaching into
/// the startup flow.
@MainActor final class LeoManagedDaemonFeed: ObservableObject {
    @Published private(set) var status: LeoManagedStatus = .inactive
    @Published private(set) var presentation = LeoManagedPresentation(status: .inactive, notice: nil)

    /// Runs a banner action; wired by the app to `LeoManagedStartup.perform`.
    var performBanner: @MainActor (LeoManagedBannerAction) -> Void = { _ in }
    /// Runs a start action; wired by the app to `LeoManagedStartup.perform`.
    var performStart: @MainActor (LeoDaemonStartAction) -> Void = { _ in }

    func update(status: LeoManagedStatus, presentation: LeoManagedPresentation) {
        self.status = status
        self.presentation = presentation
    }

    func perform(_ action: LeoManagedSettingsAction) {
        switch action {
        case .banner(let action): performBanner(action)
        case .start(let action): performStart(action)
        }
    }
}
