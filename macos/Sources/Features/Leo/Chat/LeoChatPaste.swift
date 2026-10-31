import AppKit
import LeoKit
import SwiftUI

/// What ⌘V should attach instead of pasting text. A copied file wins (Finder
/// also puts the file's name on the pasteboard as text); otherwise only an
/// image-only pasteboard attaches, so text copied with a picture (a web
/// page) still pastes as text.
enum LeoChatPaste {
    enum Payload {
        case files([URL])
        case image(LeoPastedImage)
    }

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")]

    static func payload(from pasteboard: NSPasteboard) -> Payload? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty { return .files(urls) }
        guard pasteboard.string(forType: .string) == nil else { return nil }
        for type in imageTypes {
            if let data = pasteboard.data(forType: type), let image = LeoPastedImage(data: data) { return .image(image) }
        }
        return nil
    }
}

extension LeoChatPaneModel {
    /// ⌘V in the composer: attaches a copied file or image and returns true,
    /// or returns false so the text field pastes as usual.
    func attachPaste(from pasteboard: NSPasteboard = .general, to agent: LeoAgentID) -> Bool {
        switch LeoChatPaste.payload(from: pasteboard) {
        case nil:
            return false
        case .files(let urls):
            attach(urls, to: agent)
        case .image(let image):
            do {
                let folder = attachmentDirectory.appending(path: "pasted").appending(path: UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appending(path: image.filename)
                try image.data.write(to: url)
                attach([url], to: agent)
            } catch {
                showNotice(error.localizedDescription)
            }
        }
        return true
    }
}

/// Offers ⌘V to `handle` before the focused field editor sees it; `handle`
/// returns true to swallow the key. SwiftUI's `onPasteCommand` is skipped
/// when the field editor has focus, so this watches the key itself.
struct LeoChatPasteMonitor: NSViewRepresentable {
    let isActive: Bool
    let handle: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(isActive: isActive, handle: handle)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?
        private var handle: () -> Bool = { false }

        func update(isActive: Bool, handle: @escaping () -> Bool) {
            self.handle = handle
            guard isActive else { return stop() }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Caps Lock and fn are in the device-independent mask; only these four matter.
                let isPaste = event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
                    && event.charactersIgnoringModifiers?.lowercased() == "v"
                guard isPaste, let self else { return event }
                return MainActor.assumeIsolated { self.owns(event) && self.handle() } ? nil : event
            }
        }

        /// Only a ⌘V typed into this composer's own field editor: not another
        /// window, a sheet, or another field (focus state can outlive key status).
        private func owns(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView
            else { return false }
            // The monitor view is this composer's background, so it spans exactly the
            // composer: the field being edited has to sit inside that rectangle.
            let composer = view.convert(view.bounds, to: nil)
            return composer.contains(field.convert(field.bounds, to: nil))
        }

        func stop() {
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
        }
    }
}
