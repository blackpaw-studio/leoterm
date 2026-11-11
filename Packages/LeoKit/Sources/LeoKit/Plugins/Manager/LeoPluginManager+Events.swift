import Foundation
import OSLog

/// What the slots (M4) and the app tell the manager happened.
extension LeoPluginManager {
    /// A slot was shown or asked for: send the plugin the event that makes it
    /// render. False if the manifest declares no such contribution.
    @discardableResult
    public func open(_ slot: LeoPluginSlotID, plugin id: String) -> Bool {
        guard let entry = entries[id], let manifest = entry.manifest, Self.declares(manifest, slot) else { return false }
        let event = Self.openingEvent(for: slot)
        // A command is a one-shot run, not state to restore: a restart must not run it again.
        if case .palette = slot {} else if entry.lastEvents[slot] != nil || entry.lastEvents.count < LeoPluginSlotStore.maxSlotsPerPlugin {
            entry.lastEvents[slot] = event
        }
        deps.slots.expect(pluginID: id, slot: slot)
        deliver(event, to: entry)
        return true
    }

    /// Retry on an error slot: send the event that produced it again. A crashed
    /// plugin is already restarting on its own, and a disabled one comes back
    /// through `setEnabled`, so those are left alone.
    public func retry(_ key: LeoPluginSlotKey) {
        guard let entry = entries[key.pluginID], entry.session != nil else { return }
        deps.slots.expect(pluginID: key.pluginID, slot: key.slot)
        deliver(entry.lastEvents[key.slot] ?? Self.openingEvent(for: key.slot), to: entry)
    }

    /// A click or key press on an action. `gesture` is minted by the renderer's
    /// click and keyboard paths and nowhere else. A `callback` goes to the
    /// plugin with a ref the plugin can quote once; anything else passes the gate.
    public func perform(_ action: LeoPluginAction, plugin id: String, slot: LeoPluginSlotID?, gesture: LeoPluginGesture?) {
        guard let entry = entries[id], let manifest = entry.manifest, let gate = entry.gate else { return }
        if case .callback(let callbackID, let payload) = action {
            guard let session = entry.session else { return }
            deliver(session.router.callbackEvent(id: callbackID, payload: payload, gesture: gesture, slot: slot), to: entry)
            return
        }
        let identity = LeoPluginIdentity(id: id, name: manifest.name)
        switch gate.authorize(action, gesture: gesture) {
        case .success(.perform(let allowed)): deps.actions.perform(allowed, plugin: identity, slot: slot)
        case .success(.confirm(let allowed)): deps.actions.confirm(allowed, plugin: identity)
        case .failure(let refusal):
            Self.logger.warning("[\(id, privacy: .public)] action refused: \(String(describing: refusal), privacy: .public)")
        }
    }

    /// The agent lists changed. Plugins with `agents:read` hear about it once
    /// the changes settle.
    public func agentsDidChange() {
        agentsChangeTask?.cancel()
        agentsChangeTask = Task { [weak self] in
            try? await self?.deps.sleep(self?.deps.agentsDebounce ?? 0)
            guard !Task.isCancelled, let self else { return }
            for entry in self.entries.values where entry.approved?.agents.contains(.read) == true {
                self.deliver(.agentsChanged, to: entry)
            }
        }
    }

    /// Whether one of the plugin's slots is on screen (`leo.after` waits for it).
    public func setSlotVisible(plugin id: String, visible: Bool) {
        guard let entry = entries[id] else { return }
        entry.isSlotVisible = visible
        entry.session?.timers.setSlotVisible(visible)
    }

    /// The event that makes a slot render.
    static func openingEvent(for slot: LeoPluginSlotID) -> LeoPluginEvent {
        switch slot {
        case .view(_, let agent): .viewOpened(agent: agent, slot: slot)
        case .accessory, .section: .activate(slot: slot)
        case .palette(let commandID): .command(id: commandID, slot: slot)
        }
    }

    static func declares(_ manifest: LeoPluginManifest, _ slot: LeoPluginSlotID) -> Bool {
        let contributes = manifest.contributes
        switch slot {
        case .view(let id, _): return contributes.views.contains { $0.id == id }
        case .accessory(let id, _): return contributes.rowAccessories.contains { $0.id == id }
        case .section(let id): return contributes.sidebarSections.contains { $0.id == id }
        case .palette(let id): return contributes.commands.contains { $0.id == id }
        }
    }
}
