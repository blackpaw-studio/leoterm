import AppKit
import SwiftUI

/// A run log: read-only, selectable text in an `NSTextView`. SwiftUI's `Text`
/// lays out all of a string at once, which freezes the window on the 4 MiB
/// tail a log can be; TextKit lays out only what is on screen.
struct LeoLogTextView: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.setAccessibilityLabel("Run log")
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.shown != text, let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.shown = text
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }

    final class Coordinator {
        var shown: String?
    }
}
