import AppKit

/// Leo's `NSApplication`. WebKit hands a key the page left unhandled back
/// to `sendEvent`, where every event monitor -- the app's shortcuts and
/// keybindings among them -- key equivalent, menu and window would see
/// it. Keys the agent synthesized stop here instead, before any of those.
@objc(LeoApplication) final class LeoApplication: NSApplication {
    private let syntheticInputs = NSHashTable<LeoSyntheticInput>.weakObjects()

    /// Keys `input` synthesized that come back to `sendEvent` go to it,
    /// and nowhere else.
    func routeResentKeys(to input: LeoSyntheticInput) {
        syntheticInputs.add(input)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, syntheticInputs.allObjects.contains(where: { $0.absorbResent(event) }) { return }
        super.sendEvent(event)
    }
}
