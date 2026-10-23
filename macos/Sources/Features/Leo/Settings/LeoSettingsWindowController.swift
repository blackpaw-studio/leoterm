import AppKit
import LeoKit
import SwiftUI

/// A question the window asks before it closes, shown as a sheet.
struct LeoSettingsPrompt: Equatable {
    let title: String
    let message: String
    /// In display order; the answer is an index into it.
    let buttons: [String]
}

/// Shows a prompt as a sheet on `window` and reports the chosen button.
@MainActor protocol LeoSettingsPrompting {
    func ask(_ prompt: LeoSettingsPrompt, on window: NSWindow, answer: @escaping @MainActor (Int) -> Void)
}

/// The live prompter: an `NSAlert` sheet.
struct LeoAlertPrompting: LeoSettingsPrompting {
    func ask(_ prompt: LeoSettingsPrompt, on window: NSWindow, answer: @escaping @MainActor (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        prompt.buttons.forEach { alert.addButton(withTitle: $0) }
        alert.beginSheetModal(for: window) { response in
            answer(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
    }
}

/// The Leo Settings window (Agents ▸ Machines…, a header's Edit Machine…).
/// ⌘, stays the Ghostty config. One window, with a tab per pane; Machines
/// is the first. A toolbar machine picker chooses which daemon the config
/// panes edit. Closing the window with unsaved edits asks first.
@MainActor final class LeoSettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static let machinePickerItem = NSToolbarItem.Identifier("leo.settings.machine")

    private let registry: LeoMachineRegistry
    private let clients: any LeoMachineClientResolving
    private let statsStyle: LeoStatsStyleSetting
    /// The machine of the agent selected in the sidebar, if any.
    private let selectedHost: () -> LeoHostID?
    private let prompting: any LeoSettingsPrompting
    private(set) var model: LeoMachinesSettingsModel?
    private(set) var target: LeoSettingsTargetModel?

    init(
        registry: LeoMachineRegistry, clients: any LeoMachineClientResolving, defaults: UserDefaults, selectedHost: @escaping () -> LeoHostID?,
        prompting: (any LeoSettingsPrompting)? = nil
    ) {
        self.prompting = prompting ?? LeoAlertPrompting()
        self.registry = registry
        self.clients = clients
        self.selectedHost = selectedHost
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
        let registry = registry
        let target = LeoSettingsTargetModel(
            clients: clients, machines: { registry.machines }, status: { registry.status(for: $0) },
            statuses: registry.machineStatuses, reconnect: { registry.reconnect($0) }, initialHost: selectedHost()
        )
        self.target = target
        let content = LeoSettingsView(model: model, target: target, statsStyle: statsStyle, registry: registry)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "Leo Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let toolbar = NSToolbar(identifier: "leo.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 820, height: 680))
        window.center()
        self.window = window
        return model
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.machinePickerItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.machinePickerItem]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.machinePickerItem, let target else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        let host = NSHostingView(rootView: LeoMachinePicker(target: target, registry: registry))
        host.setFrameSize(host.fittingSize)
        item.view = host
        item.label = "Machine"
        item.paletteLabel = "Machine"
        return item
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let model, model.isDirty {
            askAboutMachines(model, closing: sender)
            return false
        }
        if target?.hasUnsavedChanges == true {
            askAboutPanes(closing: sender)
            return false
        }
        return true
    }

    /// Save / Discard / Cancel on the machine list. Once answered, the close
    /// is retried with `performClose` so the panes get their own question;
    /// `close()` would skip `windowShouldClose` and drop their edits.
    private func askAboutMachines(_ model: LeoMachinesSettingsModel, closing sender: NSWindow) {
        let prompt = LeoSettingsPrompt(
            title: "Save changes to your machines?", message: "Your edits to the machine list haven't been saved.",
            buttons: ["Save", "Discard", "Cancel"]
        )
        prompting.ask(prompt, on: sender) { [weak self, weak sender] choice in
            switch choice {
            case 0: guard model.save() else { return }
            case 1: break
            default: return
            }
            self?.model = nil
            sender?.performClose(nil)
        }
    }

    private func askAboutPanes(closing sender: NSWindow) {
        let prompt = LeoSettingsPrompt(
            title: "Discard unsaved settings changes?", message: "Your edits haven't been saved to the machine.",
            buttons: ["Discard", "Cancel"]
        )
        prompting.ask(prompt, on: sender) { [weak self, weak sender] choice in
            guard choice == 0 else { return }
            self?.target?.discardAllChanges()
            sender?.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
        target = nil
    }
}

/// The tabs. Machines, then one tab per config resource; each config pane is a tab
/// whose content sits in a `LeoSettingsPaneState`, so a machine that can't be
/// edited says why instead of showing a half form.
private struct LeoSettingsView: View {
    @ObservedObject var model: LeoMachinesSettingsModel
    @ObservedObject var target: LeoSettingsTargetModel
    @ObservedObject var statsStyle: LeoStatsStyleSetting
    @ObservedObject var registry: LeoMachineRegistry

    var body: some View {
        TabView(selection: Binding(get: { target.selectedTab }, set: { _ = target.requestTab($0) })) {
            LeoMachinesSettingsView(model: model, statsStyle: statsStyle, registry: registry)
                .tabItem { Label("Machines", systemImage: "server.rack") }
                .tag(LeoSettingsTab.machines)
            LeoTemplatesSettingsView(target: target)
                .tabItem { Label("Templates", systemImage: "doc.text") }
                .tag(LeoTemplatesSettingsView.tab)
            LeoTasksSettingsView(target: target)
                .tabItem { Label("Tasks", systemImage: "clock") }
                .tag(LeoTasksSettingsView.tab)
            LeoEnvironmentsSettingsView(target: target)
                .tabItem { Label("Environments", systemImage: "leaf") }
                .tag(LeoEnvironmentsSettingsView.tab)
            LeoDelegationSettingsView(target: target)
                .tabItem { Label("Delegation", systemImage: "arrow.triangle.branch") }
                .tag(LeoDelegationSettingsView.tab)
            LeoDefaultsSettingsView(target: target)
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
                .tag(LeoDefaultsSettingsView.tab)
        }
        .alert(
            "Discard unsaved changes?",
            isPresented: Binding(get: { target.pendingChange != nil }, set: { if !$0 { target.cancelPendingChange() } })
        ) {
            Button("Discard", role: .destructive) { target.confirmPendingChange() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits haven't been saved to the machine.")
        }
    }
}
