import AppKit
import SwiftUI

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
        let sheet = NSHostingController(rootView: LeoRenameAgentSheet(row: row, actions: runtime.actions))
        window?.contentViewController?.presentAsSheet(sheet)
    }

    @IBAction func viewLogsForSelectedLeoAgent(_ sender: Any?) {
        guard let runtime = leoRuntime, let row = selectedLeoRow else { return }
        do {
            let command: String
            if case .remote(let name) = row.host {
                guard let configuration = runtime.hostSelection.hosts.first(where: { $0.name == name }) else {
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
        let sheet = NSHostingController(
            rootView: LeoDeleteAgentSheetContainer(row: row, model: runtime.model, actions: runtime.actions)
        )
        window?.contentViewController?.presentAsSheet(sheet)
    }

    @IBAction func manageLeoHosts(_ sender: Any?) {
        guard let runtime = leoRuntime else { return }
        let sheet = NSHostingController(rootView: LeoHostsSheetContainer(model: runtime.hostSelection.makeHostsSheetModel()))
        window?.contentViewController?.presentAsSheet(sheet)
    }

    @IBAction func jumpToNextLeoAgentNeedingAttention(_ sender: Any?) {
        guard let leoSession, let runtime = leoRuntime else { return }
        runtime.jumpToNextNeedingAttention(from: leoSession)
    }

    /// Agents ▸ Reconnect (⇧⌘R): the same Retry as the sidebar's banner.
    @IBAction func reconnectLeo(_ sender: Any?) {
        leoRuntime?.model.retry()
    }

    func validateLeoReconnectMenuItem(_ item: NSMenuItem) -> Bool {
        LeoMenuCommands.canReconnect(hasLeoSession: leoSession != nil, connectivity: leoRuntime?.model.snapshot.connectivity ?? .loading)
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
    func validateLeoDeleteMenuItem(_ item: NSMenuItem) -> Bool { LeoMenuCommands.canDelete(selectedLeoAgentContext) }
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
/// .templates()` each time the Agents menu is about to display, since the
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

    /// Bumped on every `menuNeedsUpdate` call and captured before the async
    /// template fetch; a fetch whose generation no longer matches the
    /// latest one when it completes belongs to a since-superseded
    /// selection and must not overwrite the submenu. Comparing
    /// `setTemplateItem.submenu === submenu` alone is not sufficient here:
    /// the submenu is the same persistent `NSMenu` instance from the xib on
    /// every call, so that identity check is always true and never
    /// actually detects a stale fetch.
    private var updateGeneration = 0

    private override init() {}

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateTemplateItem(in: menu)
        updateEnvironmentsItem(in: menu)
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
                let templates = try await runtime.actions.templates()
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
              runtime.model.hostFeatures.applying(to: row.host).contains(.agentEnvironments) else {
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
        fill(actions.environmentCatalog)
        guard actions.environmentCatalog == .loading else { return }
        Task { @MainActor [weak self] in
            for await state in actions.$environmentCatalog.values where state != .loading {
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

private struct LeoDeleteAgentSheetContainer: View {
    let row: LeoAgentRow
    @ObservedObject var model: LeoSidebarModel
    @ObservedObject var actions: LeoAgentActions

    var body: some View {
        LeoDeleteAgentSheet(row: row, actions: actions, error: model.rowErrors[row.id], errorCode: model.rowErrorCodes[row.id])
    }
}

private struct LeoHostsSheetContainer: View {
    @ObservedObject var model: LeoHostsSheetModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LeoHostsSheet(model: model) { dismiss() }
    }
}
