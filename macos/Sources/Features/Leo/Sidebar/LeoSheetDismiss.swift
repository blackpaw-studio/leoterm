import AppKit
import SwiftUI

/// Closes the sheet the view sits in. SwiftUI's `\.dismiss` is a no-op in a
/// hosting controller that `NSWindow.presentLeoSheet` attached outside
/// SwiftUI (B-328), so those presenters supply `leoSheetClose` through
/// `View.leoSheetClose(in:)`; under a SwiftUI `.sheet` it is unset and this
/// falls back to `\.dismiss`.
struct LeoSheetDismiss: DynamicProperty {
    @Environment(\.dismiss) private var swiftUIDismiss
    @Environment(\.leoSheetClose) private var windowClose

    func callAsFunction() {
        guard let windowClose else { return swiftUIDismiss() }
        windowClose()
    }
}

private struct LeoSheetCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var leoSheetClose: (() -> Void)? {
        get { self[LeoSheetCloseKey.self] }
        set { self[LeoSheetCloseKey.self] = newValue }
    }
}

extension View {
    /// Makes `LeoSheetDismiss` end the sheet attached to `window`.
    func leoSheetClose(in window: NSWindow?) -> some View {
        environment(\.leoSheetClose, { [weak window] in
            guard let window, let sheet = window.attachedSheet else { return }
            window.endSheet(sheet)
        })
    }
}
