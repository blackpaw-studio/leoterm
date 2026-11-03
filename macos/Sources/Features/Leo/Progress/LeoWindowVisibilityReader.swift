import AppKit
import SwiftUI

/// Reports whether the hosting window is on screen and not occluded, so a
/// continuous animation can pause while nobody can see it.
struct LeoWindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = { visible in
            if isVisible != visible { DispatchQueue.main.async { isVisible = visible } }
        }
        view.report()
    }

    final class ReaderView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var observer: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.report() }
            report()
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        func report() { onChange(window?.occlusionState.contains(.visible) ?? true) }
    }
}
