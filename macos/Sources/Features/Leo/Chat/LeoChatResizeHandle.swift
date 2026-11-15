import AppKit
import SwiftUI

/// The invisible grab area over the terminal | chat divider. Dragging left
/// widens the chat; double-clicking asks for the default width back. It
/// reports window-space deltas, so the handle moving as the chat resizes
/// doesn't feed back into the drag.
struct LeoChatResizeHandle: NSViewRepresentable {
    /// About 6 pt centred on the 1 pt visible line.
    static let hitWidth: CGFloat = 6

    /// The chat's width right now, read when a drag starts.
    let currentWidth: () -> CGFloat
    /// The width the pointer asks for, on every drag event (unclamped).
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> LeoChatResizeHandleView {
        let view = LeoChatResizeHandleView()
        view.setAccessibilityLabel("Resize chat")
        return view
    }

    func updateNSView(_ view: LeoChatResizeHandleView, context: Context) {
        view.currentWidth = currentWidth
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onReset = onReset
    }
}

final class LeoChatResizeHandleView: NSView {
    var currentWidth: () -> CGFloat = { 0 }
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDragEnd: () -> Void = {}
    var onReset: () -> Void = {}
    private var dragStart: (pointerX: CGFloat, width: CGFloat)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount < 2 else {
            dragStart = nil
            onReset()
            return
        }
        dragStart = (event.locationInWindow.x, currentWidth())
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        onDrag(dragStart.width - (event.locationInWindow.x - dragStart.pointerX))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onDragEnd()
    }
}
