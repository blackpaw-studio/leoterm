import Foundation

/// The words of the sidebar's full-panel connection failure. The message
/// is often a remote ssh's stderr and the hint names the configured
/// target, so both go through the one sanitizer (B-020) here.
struct LeoConnectionFailurePanel: Equatable {
    let message: String
    let hint: String?

    init(message: String, hint: String?) {
        self.message = LeoSFTPServerText.sanitized(message)
        self.hint = hint.map(LeoSFTPServerText.sanitized)
    }
}
