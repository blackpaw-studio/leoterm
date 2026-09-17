import AppKit
import SwiftUI

/// What `LeoPickerPresentation` needs from a floating palette surface.
/// Abstracted so `LeoPickerPresentationTests` can inject a fake instead of a
/// real `NSPanel` (which needs a live window server to behave correctly).
@MainActor protocol LeoAgentPalettePanelControlling: AnyObject {
    var isPresented: Bool { get }
    func present(
        parent: NSWindow,
        model: LeoAgentPaletteModel,
        onCommit: @escaping (LeoPickerChoice) -> Void,
        onRetry: @escaping () -> Void,
        onResignKey: @escaping () -> Void
    )
    func focusSearchField()
    func dismiss()
}

/// The real floating palette: a borderless, key-taking `NSPanel` attached as
/// a child window of the terminal window it was invoked from, sized and
/// positioned like a Spotlight bar. Owns no picker logic itself -- it only
/// hosts `LeoAgentPaletteView` and forwards commit/resign-key events to
/// whoever called `present(...)`.
@MainActor final class LeoAgentPalettePanel: NSPanel, LeoAgentPalettePanelControlling {
    private static let width: CGFloat = 640
    private static let minHeight: CGFloat = 140
    private static let maxHeight: CGFloat = 420
    private static let rowHeight: CGFloat = 44
    private static let headerHeight: CGFloat = 72

    private weak var attachedParent: NSWindow?
    private var onResignKeyHandler: (() -> Void)?
    private var onCommitHandler: ((LeoPickerChoice) -> Void)?
    private weak var currentModel: LeoAgentPaletteModel?

    var isPresented: Bool { attachedParent != nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: LeoAgentPalettePanel.width, height: LeoAgentPalettePanel.minHeight),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
    }

    func present(
        parent: NSWindow,
        model: LeoAgentPaletteModel,
        onCommit: @escaping (LeoPickerChoice) -> Void,
        onRetry: @escaping () -> Void,
        onResignKey: @escaping () -> Void
    ) {
        currentModel = model
        onCommitHandler = onCommit
        onResignKeyHandler = onResignKey
        contentView = NSHostingView(rootView: LeoAgentPaletteView(model: model, onCommit: onCommit, onRetry: onRetry))
        layoutHeight(rowCount: model.rows.count)
        positionOverParent(parent)
        if attachedParent !== parent {
            attachedParent?.removeChildWindow(self)
            parent.addChildWindow(self, ordered: .above)
            attachedParent = parent
        }
        makeKeyAndOrderFront(nil)
    }

    func focusSearchField() {
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        onCommitHandler = nil
        onResignKeyHandler = nil
        currentModel = nil
        guard let attachedParent else {
            orderOut(nil)
            return
        }
        attachedParent.removeChildWindow(self)
        self.attachedParent = nil
        orderOut(nil)
    }

    override func resignKey() {
        super.resignKey()
        onResignKeyHandler?()
    }

    /// Fallback for arrow/return/escape keys the SwiftUI field editor didn't
    /// consume (e.g. focus briefly outside the text field). Never acts while
    /// the field editor has marked text (an in-progress IME composition), so
    /// this can't steal a keystroke mid-composition.
    override func keyDown(with event: NSEvent) {
        guard !firstResponderHasMarkedText else {
            super.keyDown(with: event)
            return
        }
        switch event.specialKey {
        case .some(.upArrow):
            currentModel?.moveSelection(by: -1)
        case .some(.downArrow):
            currentModel?.moveSelection(by: 1)
        case .some(.carriageReturn), .some(.enter):
            if let choice = currentModel?.confirm() { onCommitHandler?(choice) }
        default:
            if event.keyCode == 53 { // Escape
                onCommitHandler?(.cancel)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// The field editor (an `NSTextView`) is the thing that actually knows
    /// about an in-progress IME composition -- `NSTextInputContext` itself
    /// has no such property.
    private var firstResponderHasMarkedText: Bool {
        (firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false
    }

    private func positionOverParent(_ parent: NSWindow) {
        let parentFrame = parent.frame
        let height = frame.height
        let x = parentFrame.midX - Self.width / 2
        let y = parentFrame.maxY - parentFrame.height / 3 - height
        setFrame(NSRect(x: x, y: y, width: Self.width, height: height), display: true)
    }

    private func layoutHeight(rowCount: Int) {
        let height = min(max(Self.headerHeight + CGFloat(rowCount) * Self.rowHeight, Self.minHeight), Self.maxHeight)
        setContentSize(NSSize(width: Self.width, height: height))
    }
}
