import Foundation

/// The per-device "Open images in full window" switch (B-458), off by
/// default: a click on an image in chat then opens it over the whole window
/// instead of in the chat pane's viewer. Stored under `defaultsKey`; the chat
/// viewer reads the same key live through `isOn(in:)`, so a change in
/// Settings reaches open windows at once.
@MainActor final class LeoChatImageOpenSetting: ObservableObject {
    static let defaultsKey = "leo.chat.imagesOpenFullWindow"

    @Published var opensFullWindow: Bool {
        didSet {
            guard opensFullWindow != oldValue else { return }
            defaults.set(opensFullWindow, forKey: Self.defaultsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        opensFullWindow = Self.isOn(in: defaults)
    }

    /// Off unless explicitly turned on: a missing or wrong-typed value is the default.
    nonisolated static func isOn(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }
}
