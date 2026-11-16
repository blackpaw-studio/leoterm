import AppKit
import Combine
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

/// The Leo Settings window (⌘,, Agents ▸ Machines…, a header's Edit Machine…).
/// A sidebar and a page, like System Settings: the sidebar selection is the
/// only way to choose what to edit, App pages and machines alike. One window;
/// it remembers the last item across opens. Closing it with unsaved edits asks
/// first.
@MainActor final class LeoSettingsWindowController: NSWindowController, NSWindowDelegate {
    /// The window's content size on first open (the mockups' 980 × 720 pt), and its floor.
    private static let defaultContentSize = NSSize(width: 980, height: 720)
    private static let minimumContentSize = NSSize(width: 760, height: 520)
    /// The sidebar's width band; the split view item clamps it (never a split view delegate).
    private static let sidebarWidth = 230.0...320.0
    private static let detailMinimumWidth: CGFloat = 520

    private let managedFeed: LeoManagedDaemonFeed
    private let registry: LeoMachineRegistry
    private let clients: any LeoMachineClientResolving
    private let statsStyle: LeoStatsStyleSetting
    private let agentBrowser: LeoAgentBrowserSetting
    /// A machine's agents as the sidebar shows them, for the Appearance preview and This Mac's count.
    private let agents: @MainActor (LeoHostID) -> [LeoAgentRow]
    private let prompting: any LeoSettingsPrompting
    /// The plugin system, once the app has started it (nil before).
    private let plugins: @MainActor () -> LeoPluginSystem?
    private let builtInPanes: LeoBuiltInPaneSettings
    private(set) var model: LeoMachinesSettingsModel?
    private(set) var target: LeoSettingsTargetModel?
    private(set) var sidebar: LeoSettingsSidebarModel?
    /// The item the window last showed: reopened on, while the machine is still there.
    private(set) var lastItem: LeoSettingsSidebarItem?
    private var titleSubscription: AnyCancellable?

    init(
        managedFeed: LeoManagedDaemonFeed? = nil, registry: LeoMachineRegistry, clients: any LeoMachineClientResolving, defaults: UserDefaults,
        agentBrowser: LeoAgentBrowserSetting? = nil, prompting: (any LeoSettingsPrompting)? = nil,
        agents: @escaping @MainActor (LeoHostID) -> [LeoAgentRow] = { _ in [] },
        plugins: @escaping @MainActor () -> LeoPluginSystem? = { nil },
        builtInPanes: LeoBuiltInPaneSettings? = nil
    ) {
        self.managedFeed = managedFeed ?? LeoManagedDaemonFeed()
        self.plugins = plugins
        self.builtInPanes = builtInPanes ?? LeoBuiltInPaneSettings(defaults: defaults)
        self.prompting = prompting ?? LeoAlertPrompting()
        self.agents = agents
        self.registry = registry
        self.clients = clients
        statsStyle = LeoStatsStyleSetting(defaults: defaults)
        self.agentBrowser = agentBrowser ?? LeoAgentBrowserSetting(defaults: defaults)
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on the item `entry` names: a fresh window starts there,
    /// an open one moves there (asking first when the page being left has
    /// unsaved edits).
    func show(_ entry: LeoSettingsEntry = .settings) {
        if let sidebar {
            sidebar.open(entry.item(remembered: sidebar.selection, configurations: registry.configurations))
        } else {
            makeWindowAndModels(opening: entry.item(remembered: lastItem, configurations: registry.configurations))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindowAndModels(opening item: LeoSettingsSidebarItem) {
        let model = registry.makeSettingsModel()
        let registry = registry
        let resolution = LeoSettingsSidebarItem.resolve(item, configurations: registry.configurations, draft: model.hosts)
        let target = LeoSettingsTargetModel(
            clients: clients, machines: { registry.machines }, status: { registry.status(for: $0) },
            statuses: registry.machineStatuses, reconnect: { registry.reconnect($0) }, initialHost: resolution.host
        )
        _ = target.requestSelection(host: resolution.host, tab: resolution.tab)
        let sidebar = LeoSettingsSidebarModel(
            model: model, target: target, status: { registry.status(for: $0) }, configurations: { registry.configurations },
            machinesChanged: registry.$machines.dropFirst().map { _ in }.eraseToAnyPublisher(), initial: resolution.item
        )
        if case .remote(let id)? = resolution.item.machine { model.selectedID = id }
        self.model = model
        self.target = target
        self.sidebar = sidebar
        let split = makeSplitViewController(sidebar: sidebar, model: model, target: target)
        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Assigning a content controller resizes the window to its fitting size.
        window.setContentSize(Self.defaultContentSize)
        window.contentMinSize = Self.minimumContentSize
        window.center()
        self.window = window
        titleSubscription = sidebar.objectWillChange.sink { [weak self] in
            // The selection changes after this fires; read it on the next turn.
            DispatchQueue.main.async { self?.syncTitle() }
        }
        syncTitle()
    }

    private func makeSplitViewController(
        sidebar: LeoSettingsSidebarModel, model: LeoMachinesSettingsModel, target: LeoSettingsTargetModel
    ) -> NSSplitViewController {
        let sidebarHost = NSHostingController(rootView: LeoSettingsSidebarView(model: sidebar, registry: registry))
        let detailHost = NSHostingController(
            rootView: LeoSettingsDetailView(
                sidebar: sidebar, model: model, target: target, statsStyle: statsStyle, agentBrowser: agentBrowser, builtInPanes: builtInPanes,
                managedFeed: managedFeed, registry: registry, agents: agents, plugins: plugins
            )
        )
        // The split view sizes its panes; a hosting controller must not also resize the window.
        sidebarHost.sizingOptions = []
        detailHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = Self.sidebarWidth.lowerBound
        sidebarItem.maximumThickness = Self.sidebarWidth.upperBound
        sidebarItem.canCollapse = false
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = Self.detailMinimumWidth
        let split = NSSplitViewController()
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        return split
    }

    /// The window's title is the page; for a machine's pane the subtitle names the machine.
    private func syncTitle() {
        guard let sidebar, let window else { return }
        let name = { (ref: LeoSettingsMachineRef) in sidebar.rows.first { $0.ref == ref }?.name ?? "Machine" }
        switch sidebar.selection {
        case .general: (window.title, window.subtitle) = ("General", "")
        case .plugins: (window.title, window.subtitle) = ("Plugins", "")
        case .machine(let ref): (window.title, window.subtitle) = (name(ref), "")
        case .pane(let ref, let pane): (window.title, window.subtitle) = (pane.title, name(ref))
        }
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
        lastItem = sidebar?.selection ?? lastItem
        // The closed window would otherwise keep its old page alive, still wired to the
        // old models, while the next open builds new ones: tear the content down with it.
        (notification.object as? NSWindow)?.contentViewController = nil
        titleSubscription = nil
        model = nil
        target = nil
        sidebar = nil
    }
}
