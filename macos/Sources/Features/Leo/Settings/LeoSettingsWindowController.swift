import AppKit
import LeoKit
import SwiftUI

/// The Leo Settings window (Agents ▸ Machines…, a header's Edit Machine…).
/// ⌘, stays the Ghostty config. One window, with a tab per pane; Machines
/// is the first. Closing it with unsaved edits asks first.
@MainActor final class LeoSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let registry: LeoMachineRegistry
    private let statsStyle: LeoStatsStyleSetting
    private var model: LeoMachinesSettingsModel?

    init(registry: LeoMachineRegistry, defaults: UserDefaults) {
        self.registry = registry
        statsStyle = LeoStatsStyleSetting(defaults: defaults)
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window with a fresh draft, or brings the open one forward.
    /// `host` selects that remote machine in the list.
    func show(selecting host: LeoHostID? = nil) {
        let model = self.model ?? makeWindowAndModel()
        if case .remote(let name)? = host, let id = model.hosts.first(where: { $0.name == name })?.id {
            model.selectedID = id
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindowAndModel() -> LeoMachinesSettingsModel {
        let model = registry.makeSettingsModel()
        self.model = model
        let content = LeoSettingsView(model: model, statsStyle: statsStyle, registry: registry)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "Leo Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 820, height: 680))
        window.center()
        self.window = window
        return model
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to your machines?"
        alert.informativeText = "Your edits to the machine list haven't been saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            switch response {
            case .alertFirstButtonReturn:
                guard model.save() else { return }
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
            self?.model = nil
            sender?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
    }
}

/// The tabs. Machines is the only pane so far.
private struct LeoSettingsView: View {
    @ObservedObject var model: LeoMachinesSettingsModel
    @ObservedObject var statsStyle: LeoStatsStyleSetting
    @ObservedObject var registry: LeoMachineRegistry

    var body: some View {
        TabView {
            LeoMachinesSettingsView(model: model, statsStyle: statsStyle, registry: registry)
                .tabItem { Label("Machines", systemImage: "server.rack") }
        }
    }
}
