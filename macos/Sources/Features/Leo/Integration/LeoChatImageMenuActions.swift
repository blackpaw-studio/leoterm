import AppKit

/// View ▸ Previous Image / Next Image (←/→, B-441): step through the images
/// of the message whose image is open full window. The arrow keys themselves
/// are taken by the viewer's key monitor first; these are the menu's route,
/// for clicks and for the menu bar's discoverability.
extension TerminalController {
    @IBAction func showPreviousLeoChatImage(_ sender: Any?) { stepLeoChatImage(-1) }

    @IBAction func showNextLeoChatImage(_ sender: Any?) { stepLeoChatImage(1) }

    func canStepLeoChatImage(_ delta: Int) -> Bool {
        guard let viewer = leoSession?.chatViewer else { return false }
        return LeoMenuCommands.canStepImage(
            delta, isFullWindow: viewer.isFullWindow, position: viewer.galleryPosition,
            isFieldEditor: (window?.firstResponder as? NSText)?.isFieldEditor == true)
    }

    private func stepLeoChatImage(_ delta: Int) {
        guard canStepLeoChatImage(delta) else { return }
        leoSession?.stepChatGallery(delta)
    }
}
