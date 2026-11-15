import AppKit

/// How Leo puts a sheet on a window. `live` is AppKit's `beginSheet` /
/// `endSheet` / `presentLeoSheet`; tests inject a recording one so sheet
/// logic is checked without a key window or a window server.
struct LeoSheetPresenter {
    /// Presents a view controller as a sheet on `window`. False when it can't.
    var presentController: @MainActor (_ controller: NSViewController, _ window: NSWindow) -> Bool
    /// Begins a ready-made sheet window on `parent`; `completion` runs when it ends.
    var presentWindow: @MainActor (_ sheet: NSWindow, _ parent: NSWindow, _ completion: @escaping () -> Void) -> Void
    /// Ends `sheet`; `parent` is nil once its window is gone.
    var dismissWindow: @MainActor (_ sheet: NSWindow, _ parent: NSWindow?) -> Void
    /// Whether `window` already shows a sheet.
    var hasSheet: @MainActor (_ window: NSWindow) -> Bool

    static let live = LeoSheetPresenter(
        presentController: { controller, window in window.presentLeoSheet(controller) },
        presentWindow: { sheet, parent, completion in parent.beginSheet(sheet) { _ in completion() } },
        dismissWindow: { sheet, parent in
            if let parent { parent.endSheet(sheet) } else { sheet.close() }
        },
        hasSheet: { $0.attachedSheet != nil }
    )
}
