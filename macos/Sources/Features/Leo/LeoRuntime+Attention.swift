import AppKit
import Foundation

/// Attention-model hooks on the runtime: focus identity into the feed's
/// reducer, and Agents ▸ Jump to Next Needing Attention.
extension LeoRuntime {
    /// Focus identity comes only from `LeoAttachCoordinator`'s
    /// handle -> identity map, never from titles or sidebar selection.
    /// Changes reach the feed in order, so it ends on the latest one.
    func focusedAgentChanged(_ identity: LeoAgentIdentity?) {
        focusedAgentRelay.send(identity.map { LeoAgentRow.ID(host: $0.host, name: $0.name) })
    }

    /// The row Jump would attach to: unfiltered sidebar order, after the
    /// focused agent (else the selection), skipping the focused agent.
    var nextAttentionTarget: LeoAgentRow? {
        let rows = LeoSidebarReducers.rank(model.snapshot.rows)
        let focused = attachCoordinator.focusedIdentity.map { LeoAgentRow.ID(host: $0.host, name: $0.name) }
        let target = LeoAttentionNavigation.next(
            in: rows.map(\.id),
            needing: LeoAttentionNavigation.needing(rows),
            focused: focused,
            selected: model.selection
        )
        return rows.first { $0.id == target }
    }

    /// Reveals `session`'s sidebar, clears a filter that would hide the
    /// target, and attaches (reusing a tab when one exists). The selection
    /// moves only once the attach succeeds.
    func jumpToNextNeedingAttention(from session: LeoWindowSession) {
        guard let row = nextAttentionTarget else { return }
        session.setSidebarVisible(true)
        if LeoAttentionNavigation.filterHides(row, query: model.query) { model.query = "" }
        let request = LeoSurfaceRequest(origin: session.id, disposition: .tab)
        Task { [weak self] in
            guard let self else { return }
            if case .success = await self.attachCoordinator.attach(identity: row.identity, request: request) {
                self.model.selection = row.id
            }
        }
    }
}

// MARK: Notifications

extension LeoRuntime {
    func attentionTransitionsCommitted(_ transitions: [LeoAttentionTransition]) {
        Task { [attentionNotifications] in await attentionNotifications.handle(transitions) }
    }

    /// Handles a click on one of our notifications (attach or focus the
    /// agent). Returns `false` for notifications that aren't Leo's.
    func openAttentionNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard let id = LeoAttentionNotification.agent(fromUserInfo: userInfo) else { return false }
        let identity = model.snapshot.rows.first { $0.id == id }?.identity ?? LeoAgentIdentity(host: id.host, name: id.name)
        let origin = (NSApp.keyWindow?.windowController as? TerminalController)?.leoSession?.id
            ?? TerminalController.preferredParent?.leoSession?.id
        let request = LeoSurfaceRequest(origin: origin ?? LeoWindowID(), disposition: origin == nil ? .window : .tab)
        NSApp.activate(ignoringOtherApps: true)
        Task { [weak self] in
            guard let self else { return }
            if case .success = await self.attachCoordinator.attach(identity: identity, request: request) {
                self.model.selection = id
            }
        }
        return true
    }

    /// Agents ▸ Agent Notifications…: a sheet to turn notifications on
    /// (requesting permission only then) or off.
    func presentAttentionNotificationSettings(for window: NSWindow?) {
        let alert = NSAlert()
        let isEnabled = attentionNotifications.isEnabled
        alert.messageText = isEnabled ? "Agent Notifications Are On" : "Turn On Agent Notifications?"
        alert.informativeText = "Leo notifies you when an agent you aren't looking at needs your input or finishes. "
            + "Notifications follow your Focus settings."
        alert.addButton(withTitle: isEnabled ? "Turn Off" : "Turn On")
        alert.addButton(withTitle: "Cancel")
        let apply: (NSApplication.ModalResponse) -> Void = { [attentionNotifications] response in
            guard response == .alertFirstButtonReturn else { return }
            if isEnabled {
                attentionNotifications.disable()
            } else {
                Task { await attentionNotifications.enable() }
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    static func presentNotificationsDeniedInstructions() {
        let alert = NSAlert()
        alert.messageText = "Notifications Are Off for Leo"
        alert.informativeText = "To get agent notifications, allow notifications for Leo in "
            + "System Settings > Notifications, then choose Agents > Agent Notifications… again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
