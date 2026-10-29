import AppKit
import SwiftUI
import LeoKit

// MARK: Menu bar actions

/// `@IBAction`s and validators for the "Agents" menu bar items that act on
/// the sidebar's *current selection* (Attach, Start, Stop, Restart,
/// Rename…, View Logs, Delete). "Set Template" is handled separately by
/// `LeoAgentsMenuController` below since its submenu is populated
/// dynamically. All of these supplement, rather than replace, the
/// equivalent commands already reachable from `LeoAgentRow`'s row context
/// menu -- both paths call through the same `LeoAgentActions`/
/// `LeoRowActionAvailability` so they can never disagree.
extension TerminalController {
    @IBAction func attachSelectedLeoAgent(_ sender: Any?) {
        guard let leoSession, let runtime = leoRuntime, let row = selectedLeoRow else { return }
        let disposition = LeoAttachActivation.disposition(for: NSEvent.modifierFlags)
        runtime.model.requestAttach(row, from: leoSession.id, disposition: disposition)
    }

    @IBAction func startSelectedLeoAgent(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow else { return }
        runtime.actions.start(row)
    }

    @IBAction func stopSelectedLeoAgent(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow else { return }
        runtime.actions.stop(row)
    }

    @IBAction func restartSelectedLeoAgent(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow else { return }
        runtime.actions.restart(row)
    }

    @IBAction func renameSelectedLeoAgent(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow else { return }
        LeoAgentMenuSheets(runtime: runtime).presentRename(row, in: window)
    }

    @IBAction func viewLogsForSelectedLeoAgent(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow else { return }
        do {
            let command: String
            if case .remote(let name) = row.host {
                guard let configuration = runtime.machines.configuration(for: row.host) else {
                    throw LeoDaemonError.hostUnavailable("Remote host \(name) is not configured")
                }
                command = try LeoSSHCommand(configuration: configuration).logsShellCommand(agent: row.name)
            } else {
                command = try LeoLogsCommand.build(executablePath: runtime.resolveExecutablePath(), agentName: row.name)
            }
            guard LeoCommandLauncher.openWindow(in: self, command: command) else {
                runtime.actions.setRowError("Unable to open a terminal window", for: row)
                return
            }
        } catch {
            runtime.actions.setRowError(error.localizedDescription, for: row)
        }
    }

    @IBAction func deleteSelectedLeoAgent(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow else { return }
        LeoAgentMenuSheets(runtime: runtime).presentDelete(row, in: window)
    }

    /// Agents ▸ Duplicate… (⌃⌘D): a copy on the agent's own host.
    @IBAction func duplicateSelectedLeoAgent(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow, LeoMenuCommands.canDuplicate(selectedLeoAgentContext) else { return }
        LeoMoveFlow.copy(row, to: nil, actions: runtime.actions, in: window)
    }

    /// Agents ▸ Move To / Copy To parents. Their submenus do the work; the
    /// actions exist so AppKit validates the parents (a submenu parent with no
    /// action is always enabled) and, if it ever fires them, they open the list.
    @IBAction func moveSelectedLeoAgent(_ sender: Any?) {
        _ = LeoAgentsMenuController.shared.popMoveMenu(.move, in: window)
    }

    @IBAction func copySelectedLeoAgent(_ sender: Any?) {
        _ = LeoAgentsMenuController.shared.popMoveMenu(.copy, in: window)
    }

    /// Agents ▸ Set Template parent. Its submenu does the work; the action
    /// exists so AppKit validates the parent (a submenu parent with no action
    /// is always enabled, whatever its `isEnabled`).
    @IBAction func setTemplateForSelectedLeoAgent(_ sender: Any?) {}

    @IBAction func jumpToNextLeoAgentNeedingAttention(_ sender: Any?) {
        guard let leoSession, let runtime = leoRuntime else { return }
        runtime.jumpToNextNeedingAttention(from: leoSession)
    }

    /// Agents ▸ Reconnect (⇧⌘R): every machine a banner would offer
    /// Retry for (Q7).
    @IBAction func reconnectLeo(_ sender: Any?) {
        leoRuntime?.model.retry()
    }

    func validateLeoReconnectMenuItem(_ item: NSMenuItem) -> Bool {
        LeoMenuCommands.canReconnect(hasLeoSession: leoSession != nil, machines: leoRuntime?.model.machineConnectivity ?? [])
    }

    @IBAction func showLeoAgentNotificationSettings(_ sender: Any?) {
        leoRuntime?.presentAttentionNotificationSettings(for: window)
    }

    func validateLeoJumpToAttentionMenuItem(_ item: NSMenuItem) -> Bool {
        LeoMenuCommands.canJumpToNextNeedingAttention(
            hasLeoSession: leoSession != nil,
            hasTarget: leoRuntime?.nextAttentionTarget != nil
        )
    }

    func validateLeoAttachMenuItem(_ item: NSMenuItem) -> Bool {
        installLeoAgentsMenuDelegateIfNeeded(item.menu)
        return LeoMenuCommands.canAttach(selectedLeoAgentContext)
    }

    func validateLeoStartMenuItem(_ item: NSMenuItem) -> Bool { LeoMenuCommands.canStart(selectedLeoAgentContext) }
    func validateLeoStopMenuItem(_ item: NSMenuItem) -> Bool { LeoMenuCommands.canStop(selectedLeoAgentContext) }
    func validateLeoRestartMenuItem(_ item: NSMenuItem) -> Bool { LeoMenuCommands.canRestart(selectedLeoAgentContext) }
    func validateLeoRenameMenuItem(_ item: NSMenuItem) -> Bool { LeoMenuCommands.canRename(selectedLeoAgentContext) }
    func validateLeoViewLogsMenuItem(_ item: NSMenuItem) -> Bool { LeoMenuCommands.canViewLogs(selectedLeoAgentContext) }
    func validateLeoSetTemplateMenuItem(_ item: NSMenuItem) -> Bool { LeoMenuCommands.canSetTemplate(selectedLeoAgentContext) }
    func validateLeoDeleteMenuItem(_ item: NSMenuItem) -> Bool { LeoMenuCommands.canDelete(selectedLeoAgentContext) }
    func validateLeoDuplicateMenuItem(_ item: NSMenuItem) -> Bool { validateLeoMoveMenuItem(item, LeoMenuCommands.canDuplicate) }
    func validateLeoMoveMenuItem(_ item: NSMenuItem, _ can: (LeoMenuCommands.AgentContext) -> Bool) -> Bool {
        let context = selectedLeoAgentContext
        item.isHidden = !LeoMenuCommands.showsMoveItems(context)
        return can(context)
    }
    func validateLeoManageHostsMenuItem(_ item: NSMenuItem) -> Bool { leoRuntime != nil }

    /// Installs the "Set Template" submenu controller on the Agents menu
    /// the first time any of its items validate. Lazy because the menu
    /// itself lives in `MainMenu.xib` (app-wide, one instance) with no
    /// natural per-window owner to wire the delegate outlet to at load
    /// time; every window's `TerminalController` is an equally good place
    /// to install it exactly once.
    private func installLeoAgentsMenuDelegateIfNeeded(_ menu: NSMenu?) {
        guard let menu, menu.delegate == nil else { return }
        menu.delegate = LeoAgentsMenuController.shared
    }
}

// MARK: Set Template submenu

/// Lazily populates the "Set Template" submenu from `LeoAgentActions
/// .templates(for:)` each time the Agents menu is about to display, since the
/// list of templates isn't known statically. Reads the *current key
/// window's* selection fresh on every open rather than caching state, so
/// one shared instance can serve every window.
@MainActor final class LeoAgentsMenuController: NSObject, NSMenuDelegate {
    static let shared = LeoAgentsMenuController()

    /// Matches the `identifier` set on the "Set Template" item in
    /// `MainMenu.xib`. Looking items up by this rather than by title means
    /// renaming or localizing the title can never silently break the
    /// submenu population.
    static let setTemplateItemIdentifier = NSUserInterfaceItemIdentifier("leo.agents.setTemplate")
    /// B-283: "Set Environments", right after Set Template; hidden unless
    /// the selected row's host advertises `agent_environments`.
    static let setEnvironmentsItemIdentifier = NSUserInterfaceItemIdentifier("leo.agents.setEnvironments")
    /// "Switch to", right after Set Environments: one pick sets a sole
    /// environment. Shown and hidden with Set Environments.
    static let switchEnvironmentItemIdentifier = NSUserInterfaceItemIdentifier("leo.agents.switchEnvironment")
    /// B-324: "Move To" and "Copy To", right after Switch to.
    static let moveToItemIdentifier = NSUserInterfaceItemIdentifier("leo.agents.moveTo")
    static let copyToItemIdentifier = NSUserInterfaceItemIdentifier("leo.agents.copyTo")

    /// Bumped on every `menuNeedsUpdate` call and captured before the async
    /// template fetch; a fetch whose generation no longer matches the
    /// latest one when it completes belongs to a since-superseded
    /// selection and must not overwrite the submenu. Comparing
    /// `setTemplateItem.submenu === submenu` alone is not sufficient here:
    /// the submenu is the same persistent `NSMenu` instance from the xib on
    /// every call, so that identity check is always true and never
    /// actually detects a stale fetch.
    private var updateGeneration = 0

    private var shortcutMonitor: Any?

    /// The one pending "Loading…" refill; each open replaces it.
    private var moveWait: Task<Void, Never>?

    private override init() {}

    /// Starts matching ⇧⌃⌘M / ⇧⌃⌘C (see `LeoMoveMenu.shortcut`). Idempotent.
    func installMoveShortcuts() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let kind = LeoMoveMenu.shortcut(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
                  self?.popMoveMenu(kind, in: event.window) == true else { return event }
            return nil
        }
    }

    /// Pops the Move To / Copy To list for the selected row at the pointer.
    /// False, and nothing happens, when no row is selected or can't move.
    func popMoveMenu(_ kind: LeoMoveKind, in window: NSWindow?) -> Bool {
        guard let controller = window?.windowController as? TerminalController,
              let view = window?.contentView, let agentsMenu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
                  menu.items.contains { $0.identifier == Self.moveToItemIdentifier }
              }) else { return false }
        let context = controller.selectedLeoAgentContext
        guard kind == .move ? LeoMenuCommands.canMove(context) : LeoMenuCommands.canCopy(context) else { return false }
        updateMoveItems(in: agentsMenu)
        let identifier = kind == .move ? Self.moveToItemIdentifier : Self.copyToItemIdentifier
        guard let submenu = agentsMenu.items.first(where: { $0.identifier == identifier })?.submenu else { return false }
        submenu.popUp(positioning: nil, at: view.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil), in: view)
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateTemplateItem(in: menu)
        updateEnvironmentsItem(in: menu)
        updateMoveItems(in: menu)
    }

    /// Move To and Copy To list the selected agent's host's destinations,
    /// read from the list `LeoAgentActions` prefetched on connect.
    private func updateMoveItems(in menu: NSMenu) {
        let kinds: [(NSUserInterfaceItemIdentifier, LeoMoveKind)] = [(Self.moveToItemIdentifier, .move), (Self.copyToItemIdentifier, .copy)]
        let targets = kinds.compactMap { identifier, kind in
            menu.items.first(where: { $0.identifier == identifier }).flatMap { item in item.submenu.map { (item, $0, kind) } }
        }
        guard !targets.isEmpty else { return }
        moveWait?.cancel()
        moveWait = nil
        guard let controller = NSApp.keyWindow?.windowController as? TerminalController,
              let row = controller.selectedLeoRow, let runtime = controller.leoRuntime else {
            for (_, submenu, _) in targets { submenu.items = [Self.placeholderItem(title: "No Agent Selected")] }
            return
        }
        let actions = runtime.actions
        let fill = { [weak self] (destinations: LeoMoveDestinations?) in
            guard let self else { return }
            for (_, submenu, kind) in targets {
                submenu.items = LeoMoveMenu.entries(destinations).map { self.moveMenuItem(for: $0, kind: kind, row: row, actions: actions) }
            }
        }
        let host = row.host
        fill(actions.moveDestinations(for: host))
        guard actions.moveDestinations(for: host) == nil else { return }
        moveWait = Task { @MainActor in
            guard let loaded = await actions.loadedMoveDestinations(for: host), !Task.isCancelled else { return }
            fill(loaded)
        }
    }

    private func moveMenuItem(for entry: LeoMoveMenuEntry, kind: LeoMoveKind, row: LeoAgentRow, actions: LeoAgentActions) -> NSMenuItem {
        switch entry {
        case .placeholder(let title):
            return Self.placeholderItem(title: title)
        case .host(let host):
            let item = NSMenuItem(title: host, action: #selector(selectMoveDestination(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = LeoMoveSelection(isMove: kind == .move, host: host, row: row, actions: actions)
            return item
        }
    }

    @objc private func selectMoveDestination(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? LeoMoveSelection else { return }
        let window = NSApp.keyWindow
        if selection.isMove {
            LeoMoveFlow.move(selection.row, to: selection.host, actions: selection.actions, in: window)
        } else {
            LeoMoveFlow.copy(selection.row, to: selection.host, actions: selection.actions, in: window)
        }
    }

    private func updateTemplateItem(in menu: NSMenu) {
        guard let setTemplateItem = menu.items.first(where: { $0.identifier == Self.setTemplateItemIdentifier }),
              let submenu = setTemplateItem.submenu else { return }

        updateGeneration += 1
        let generation = updateGeneration

        guard let controller = NSApp.keyWindow?.windowController as? TerminalController else {
            setTemplateItem.isEnabled = false
            submenu.items = [Self.placeholderItem(title: "No Window")]
            return
        }

        let context = controller.selectedLeoAgentContext
        setTemplateItem.isEnabled = LeoMenuCommands.canSetTemplate(context)

        guard let row = controller.selectedLeoRow, let runtime = controller.leoRuntime else {
            submenu.items = [Self.placeholderItem(title: "No Agent Selected")]
            return
        }

        submenu.items = [Self.placeholderItem(title: "Loading…")]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let templates = try await runtime.actions.templates(for: row.host)
                // Bail if a newer selection has since started its own fetch.
                guard self.updateGeneration == generation else { return }
                submenu.items = templates.isEmpty
                    ? [Self.placeholderItem(title: "No Templates")]
                    : templates.map { self.templateMenuItem(for: $0, row: row, runtime: runtime) }
            } catch {
                guard self.updateGeneration == generation else { return }
                submenu.items = [Self.placeholderItem(title: "Templates Unavailable")]
            }
        }
    }

    /// Built from the same entries as the row's context menu. The catalog
    /// is prefetched on each daemon bind; while it loads, the submenus show
    /// "Loading…" and fill in when it lands, unless the menu was rebuilt.
    private func updateEnvironmentsItem(in menu: NSMenu) {
        let builders: [(NSUserInterfaceItemIdentifier, (LeoEnvironmentCatalogState, LeoAgentEnvironments?) -> [LeoEnvironmentMenuEntry])] = [
            (Self.setEnvironmentsItemIdentifier, { LeoEnvironmentMenu.entries(catalog: $0, current: $1) }),
            (Self.switchEnvironmentItemIdentifier, { LeoEnvironmentSwitchMenu.entries(catalog: $0, current: $1) }),
        ]
        let targets = builders.compactMap { identifier, entries in
            menu.items.first(where: { $0.identifier == identifier }).flatMap { item in item.submenu.map { (item, $0, entries) } }
        }
        guard !targets.isEmpty else { return }
        let generation = updateGeneration
        guard let controller = NSApp.keyWindow?.windowController as? TerminalController,
              let row = controller.selectedLeoRow, let runtime = controller.leoRuntime,
              runtime.model.features(for: row.host).contains(.agentEnvironments) else {
            for (item, submenu, _) in targets {
                item.isHidden = true
                submenu.items = [Self.placeholderItem(title: "No Agent Selected")]
            }
            return
        }
        let actions = runtime.actions
        for (item, _, _) in targets {
            item.isHidden = false
            item.isEnabled = LeoMenuCommands.canSetTemplate(controller.selectedLeoAgentContext)
        }
        let fill = { [weak self, weak controller] (catalog: LeoEnvironmentCatalogState) in
            guard let self else { return }
            for (_, submenu, entries) in targets {
                submenu.items = entries(catalog, row.environments).map {
                    self.environmentMenuItem(for: $0, row: row, actions: actions, window: controller?.window)
                }
            }
        }
        let host = row.host
        fill(actions.environmentCatalog(for: host))
        guard actions.environmentCatalog(for: host) == .loading else { return }
        Task { @MainActor [weak self] in
            for await catalogs in actions.$environmentCatalogs.values {
                let state = catalogs[host] ?? .loading
                guard state != .loading else { continue }
                guard let self, self.updateGeneration == generation else { return }
                fill(state)
                return
            }
        }
    }

    private func environmentMenuItem(
        for entry: LeoEnvironmentMenuEntry, row: LeoAgentRow, actions: LeoAgentActions, window: NSWindow?
    ) -> NSMenuItem {
        let title: String
        let isEnabled: Bool
        switch entry {
        case .separator: return .separator()
        case .placeholder(let text): return Self.placeholderItem(title: text)
        case .toggle(let name, _): (title, isEnabled) = (name, true)
        case .switchTo(let name, let isCurrent): (title, isEnabled) = (name, !isCurrent)
        case .editOrder(let enabled): (title, isEnabled) = (LeoEnvironmentMenu.editOrderTitle, enabled)
        case .reset(let enabled): (title, isEnabled) = (LeoEnvironmentMenu.resetTitle, enabled)
        }
        let item = NSMenuItem(title: title, action: isEnabled ? #selector(selectEnvironmentEntry(_:)) : nil, keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        switch entry {
        case .toggle(_, let isOn): item.state = isOn ? .on : .off
        case .switchTo(_, let isCurrent): item.state = isCurrent ? .on : .off
        default: break
        }
        item.representedObject = LeoEnvironmentSelection(entry: entry, row: row, actions: actions, window: window)
        return item
    }

    @objc private func selectEnvironmentEntry(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? LeoEnvironmentSelection else { return }
        LeoEnvironmentChange.perform(selection.entry, row: selection.row, actions: selection.actions, window: selection.window ?? NSApp.keyWindow)
    }

    private func templateMenuItem(for template: LeoTemplate, row: LeoAgentRow, runtime: LeoRuntime) -> NSMenuItem {
        let item = NSMenuItem(title: template.name, action: #selector(selectTemplate(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = LeoTemplateSelection(row: row, templateName: template.name, runtime: runtime)
        item.state = template.name == row.template ? .on : .off
        return item
    }

    @objc private func selectTemplate(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? LeoTemplateSelection else { return }
        selection.runtime.actions.setTemplate(selection.row, template: selection.templateName)
    }

    private static func placeholderItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

private struct LeoMoveSelection {
    let isMove: Bool
    let host: String
    let row: LeoAgentRow
    let actions: LeoAgentActions
}

private struct LeoEnvironmentSelection {
    let entry: LeoEnvironmentMenuEntry
    let row: LeoAgentRow
    let actions: LeoAgentActions
    weak var window: NSWindow?
}

private struct LeoTemplateSelection {
    let row: LeoAgentRow
    let templateName: String
    let runtime: LeoRuntime
}

// MARK: Menu-triggered sheets
//
// Rename and Delete reuse the exact sheet views the sidebar row's context
// menu presents (`LeoAgentSheets.swift`) so the two entry points can never
// drift apart. The delete sheet takes plain `error`/`errorCode` values
// rather than observing a model directly, so a standalone
// `NSHostingController` sheet (which isn't part of any reactive SwiftUI
// tree that would re-supply them) needs this thin wrapper to keep the
// error banner live while the sheet is open.

/// Presents those sheets on a window. Built from explicit dependencies so a
/// test can hand it a fake daemon's actions instead of the app runtime's
/// (B-285); the menu actions pass the runtime's own.
@MainActor struct LeoAgentMenuSheets {
    let model: LeoSidebarModel
    let actions: LeoAgentActions

    init(model: LeoSidebarModel, actions: LeoAgentActions) {
        self.model = model
        self.actions = actions
    }

    init(runtime: LeoRuntime) {
        self.init(model: runtime.model, actions: runtime.actions)
    }

    func presentRename(_ row: LeoAgentRow, in window: NSWindow?) {
        window?.presentLeoSheet(NSHostingController(
            rootView: LeoRenameAgentSheet(row: row, actions: actions).leoSheetClose(in: window)
        ))
    }

    func presentDelete(_ row: LeoAgentRow, in window: NSWindow?) {
        window?.presentLeoSheet(NSHostingController(
            rootView: LeoDeleteAgentSheetContainer(row: row, model: model, actions: actions).leoSheetClose(in: window)
        ))
    }
}

private struct LeoDeleteAgentSheetContainer: View {
    let row: LeoAgentRow
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var actions: LeoAgentActions

    var body: some View {
        LeoDeleteAgentSheet(row: row, actions: actions, error: model.rowErrors[row.id], errorCode: model.rowErrorCodes[row.id])
    }
}
