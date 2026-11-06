import AppKit

@testable import Ghostty

/// Stands in for `LeoSheetPresenter.live`: records what would have been
/// presented and dismissed and never touches AppKit's sheet machinery, so
/// the tests need no key window, no window server focus and no run loop.
/// `dismiss` fires the stored completion like `endSheet` does.
@MainActor final class RecordingSheetPresenter {
    private(set) var presentedControllers: [NSViewController] = []
    private(set) var presentedSheets: [NSWindow] = []
    private(set) var dismissedSheets: [NSWindow] = []
    private var completions: [ObjectIdentifier: () -> Void] = [:]
    private var open: Set<ObjectIdentifier> = []

    /// A window that is never ordered in: only an identity to present on.
    static func plainWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        return window
    }

    var presenter: LeoSheetPresenter {
        LeoSheetPresenter(
            presentController: { [self] controller, _ in
                presentedControllers.append(controller)
                return true
            },
            presentWindow: { [self] sheet, _, completion in
                presentedSheets.append(sheet)
                open.insert(ObjectIdentifier(sheet))
                completions[ObjectIdentifier(sheet)] = completion
            },
            dismissWindow: { [self] sheet, _ in
                dismissedSheets.append(sheet)
                open.remove(ObjectIdentifier(sheet))
                completions.removeValue(forKey: ObjectIdentifier(sheet))?()
            },
            hasSheet: { [self] _ in !open.isEmpty }
        )
    }
}
