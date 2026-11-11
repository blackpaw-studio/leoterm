import Combine
import Foundation

public struct LeoPluginSlotKey: Hashable, Sendable {
    public let pluginID: String
    public let slot: LeoPluginSlotID

    public init(pluginID: String, slot: LeoPluginSlotID) {
        self.pluginID = pluginID
        self.slot = slot
    }
}

/// What a slot shows right now.
public enum LeoPluginSlotState: Equatable, Sendable {
    /// Nothing rendered yet.
    case loading
    case tree(LeoPluginSlotRoot)
    /// A failure; the slot offers Retry.
    case error(String)
    /// The plugin is switched off or crash-disabled; the slot shows the notice.
    case disabled(String)
}

/// A plugin as the slots see it. It overrides every slot of that plugin.
public enum LeoPluginSlotStatus: Equatable, Sendable {
    case running
    /// Crashed and waiting to restart (or failed to start).
    case failed(reason: String)
    case disabled(reason: String)
}

/// What every slot renders from, keyed by plugin and slot. Main-actor and
/// observable, so the AppKit renderers (M4) can subscribe.
@MainActor public final class LeoPluginSlotStore: ObservableObject {
    /// A plugin can't make the store grow without bound by rendering to endless agents.
    public static let maxSlotsPerPlugin = 1024
    public static let maxPushedDepth = 16

    @Published public private(set) var trees: [LeoPluginSlotKey: LeoPluginSlotRoot] = [:]
    @Published public private(set) var slotErrors: [LeoPluginSlotKey: String] = [:]
    @Published public private(set) var pushed: [LeoPluginSlotKey: [LeoPluginNode]] = [:]
    @Published public private(set) var statuses: [String: LeoPluginSlotStatus] = [:]
    private var knownSlots: [String: Set<LeoPluginSlotID>] = [:]

    public init() {}

    public func state(_ key: LeoPluginSlotKey) -> LeoPluginSlotState {
        switch statuses[key.pluginID] ?? .running {
        case .failed(let reason): return .error(reason)
        case .disabled(let reason): return .disabled(reason)
        case .running: break
        }
        if let message = slotErrors[key] { return .error(message) }
        if let tree = trees[key] { return .tree(tree) }
        return .loading
    }

    public func state(pluginID: String, slot: LeoPluginSlotID) -> LeoPluginSlotState {
        state(LeoPluginSlotKey(pluginID: pluginID, slot: slot))
    }

    /// Slots that have rendered or been marked, for one plugin.
    public func slots(of pluginID: String) -> [LeoPluginSlotID] { Array(knownSlots[pluginID] ?? []) }

    /// Stores a render. False when the plugin is already at its slot cap.
    @discardableResult
    public func render(pluginID: String, slot: LeoPluginSlotID, root: LeoPluginSlotRoot) -> Bool {
        guard track(pluginID, slot) else { return false }
        let key = LeoPluginSlotKey(pluginID: pluginID, slot: slot)
        trees[key] = root
        slotErrors[key] = nil
        pushed[key] = nil
        return true
    }

    /// Marks one slot as failed (Retry re-sends the event that produced it).
    public func fail(pluginID: String, slot: LeoPluginSlotID, message: String) {
        guard track(pluginID, slot) else { return }
        slotErrors[LeoPluginSlotKey(pluginID: pluginID, slot: slot)] = message
    }

    /// A handler threw before anything rendered: every slot still waiting shows the error.
    public func failLoadingSlots(pluginID: String, message: String) {
        for slot in knownSlots[pluginID] ?? [] {
            let key = LeoPluginSlotKey(pluginID: pluginID, slot: slot)
            if trees[key] == nil, slotErrors[key] == nil { slotErrors[key] = message }
        }
    }

    /// A slot is about to be asked for: it shows Loading until the plugin
    /// renders it. A command is a fresh run each time, so asking again drops
    /// the page and pushed views the last run left behind.
    public func expect(pluginID: String, slot: LeoPluginSlotID) {
        guard track(pluginID, slot) else { return }
        let key = LeoPluginSlotKey(pluginID: pluginID, slot: slot)
        slotErrors[key] = nil
        if case .palette = slot {
            trees[key] = nil
            pushed[key] = nil
        }
    }

    public func setStatus(pluginID: String, _ status: LeoPluginSlotStatus) {
        statuses[pluginID] = status == .running ? nil : status
    }

    /// A new host session: everything the old one rendered goes back to Loading.
    public func reset(pluginID: String) {
        trees = trees.filter { $0.key.pluginID != pluginID }
        slotErrors = slotErrors.filter { $0.key.pluginID != pluginID }
        pushed = pushed.filter { $0.key.pluginID != pluginID }
        knownSlots[pluginID] = nil
        statuses[pluginID] = nil
    }

    public func remove(pluginID: String) { reset(pluginID: pluginID) }

    // MARK: Pushed views (palette `pushView`)

    @discardableResult
    public func push(_ node: LeoPluginNode, onto key: LeoPluginSlotKey) -> Bool {
        var stack = pushed[key] ?? []
        guard stack.count < Self.maxPushedDepth else { return false }
        stack.append(node)
        pushed[key] = stack
        return true
    }

    public func pop(_ key: LeoPluginSlotKey) {
        guard var stack = pushed[key], !stack.isEmpty else { return }
        stack.removeLast()
        pushed[key] = stack.isEmpty ? nil : stack
    }

    // MARK: Private

    private func track(_ pluginID: String, _ slot: LeoPluginSlotID) -> Bool {
        var slots = knownSlots[pluginID] ?? []
        if slots.contains(slot) { return true }
        guard slots.count < Self.maxSlotsPerPlugin else { return false }
        slots.insert(slot)
        knownSlots[pluginID] = slots
        return true
    }
}
