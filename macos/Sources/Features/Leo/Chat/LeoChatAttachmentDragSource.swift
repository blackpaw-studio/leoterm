import AppKit
import ImageIO
import SwiftUI

/// The AppKit half of dragging a chat attachment out to Finder (B-346).
/// SwiftUI can't hand AppKit a file promise, so a transparent overlay
/// owns the left mouse button on the attachment, like `SurfaceDragSource`:
/// a press that moves past the threshold starts a dragging session with
/// the attachment's promise; one that doesn't is a click. Every other
/// event -- right click, control click, hover -- falls through to the
/// SwiftUI view underneath, so its context menu and help tag still work.
struct LeoChatAttachmentDragSource: NSViewRepresentable {
    /// Runs when the drag starts (not before): the machine to download
    /// from is fixed then.
    let makePromise: @MainActor () -> LeoFilePromise
    /// The picture that follows the pointer.
    let preview: @MainActor () -> NSImage
    let onClick: @MainActor () -> Void

    func makeNSView(context: Context) -> LeoChatAttachmentDragView { LeoChatAttachmentDragView() }

    func updateNSView(_ view: LeoChatAttachmentDragView, context: Context) {
        view.makePromise = makePromise
        view.preview = preview
        view.onClick = onClick
    }

    /// A thumbnail of the image at `url`, decoded by ImageIO without
    /// reading the whole picture; the file's icon when that fails.
    static func thumbnail(of url: URL, fallback: NSImage, maxPixels: Int = LeoChatAttachmentDragView.previewPixels) -> NSImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return fallback }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

final class LeoChatAttachmentDragView: NSView, NSDraggingSource {
    /// Pixels the pointer moves before a press becomes a drag.
    static let dragThreshold: CGFloat = 4
    static let previewPixels = 160

    var makePromise: (@MainActor () -> LeoFilePromise)?
    var preview: (@MainActor () -> NSImage)?
    var onClick: (@MainActor () -> Void)?

    private var pressOrigin: NSPoint?
    private var isDragging = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Only a plain left press belongs to this view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              !event.modifierFlags.contains(.control) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let origin = pressOrigin,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= Self.dragThreshold,
              let makePromise, let preview else { return }
        isDragging = true
        let image = preview()
        let item = NSDraggingItem(pasteboardWriter: makePromise())
        let size = image.size
        let mouse = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height), contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressOrigin = nil }
        guard !isDragging, pressOrigin != nil else { return }
        onClick?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        pressOrigin = nil
    }
}
