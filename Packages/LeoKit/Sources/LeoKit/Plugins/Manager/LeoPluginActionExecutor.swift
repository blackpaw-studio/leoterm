import Foundation

/// What the daemon is asked to do for a confirmed action. One value per
/// machine; the Mac app wraps `LeoDaemonClient` (`LeoDaemonClientCommands`).
public protocol LeoPluginAgentCommands: Sendable {
    func message(_ name: String, text: String) async throws
    func spawn(_ request: LeoSpawnRequest) async throws
}

/// The `LeoDaemonClient` of one machine, narrowed to what plugins may confirm.
public struct LeoDaemonClientCommands: LeoPluginAgentCommands {
    private let client: any LeoDaemonClient

    public init(_ client: any LeoDaemonClient) { self.client = client }

    public func message(_ name: String, text: String) async throws { _ = try await client.message(name, text: text) }
    public func spawn(_ request: LeoSpawnRequest) async throws { _ = try await client.spawn(request) }
}

/// Machines by the name plugins use (`LeoHostID.displayName`), and a live
/// connection to each that has one.
@MainActor public protocol LeoPluginDaemonAccess: AnyObject {
    var machines: [String] { get }
    /// Leo's default machine for new agents.
    var defaultMachine: String { get }
    /// Nil while that machine has no connection (connecting, failed, disabled, unknown).
    func commands(forMachine name: String) -> (any LeoPluginAgentCommands)?
}

public struct LeoPluginSendDraft: Equatable, Sendable {
    public let pluginName: String
    public let agent: LeoPluginAgentRef
    public let text: String
}

public struct LeoPluginSpawnDraft: Equatable, Sendable {
    public let pluginName: String
    /// What the plugin proposed; `machine` is always set (Leo's default when the plugin gave none).
    public let spec: LeoPluginSpawnSpec
    public let machines: [String]
}

/// The native confirmation sheets. The Mac app presents them; they return what
/// the person ended up with, or nil if they cancelled.
@MainActor public protocol LeoPluginConfirming: AnyObject {
    /// The edited message text.
    func confirmSend(_ draft: LeoPluginSendDraft) async -> String?
    /// The edited spawn fields, including the machine.
    func confirmSpawn(_ draft: LeoPluginSpawnDraft) async -> LeoPluginSpawnSpec?
}

/// The side effects of the harmless actions, and how failures reach the person.
@MainActor public protocol LeoPluginActionEffects: AnyObject {
    func open(_ url: URL)
    func copy(_ text: String)
    func report(plugin: LeoPluginIdentity, message: String)
}

/// Carries out actions that passed `LeoPluginActionGate`.
///
/// Send and spawn only ever happen from `confirm`: the sheet opens first,
/// nothing reaches a daemon while it is open, and what is sent is what the
/// person left in the sheet. `perform` never does either, whatever it is given.
@MainActor public final class LeoPluginActionExecutor: LeoPluginActionRunning {
    public static let maxTextBytes = 32 * 1024
    /// Sheets waiting at once, per plugin. A plugin needs a click for each, so
    /// this only bounds a runaway, and one plugin can't use up another's.
    public static let maxPendingConfirmations = 3

    private let daemons: any LeoPluginDaemonAccess
    private let confirmer: any LeoPluginConfirming
    private let effects: any LeoPluginActionEffects
    private let slots: LeoPluginSlotStore
    /// Open confirmations by plugin, by token. A sheet that never reports back
    /// is freed by `cancelPending`, not left holding a slot forever.
    private var pending: [String: [UUID: Task<Void, Never>]] = [:]
    /// Bumped by `cancelPending`; a run that started under an older value is dead.
    private var generations: [String: Int] = [:]

    public init(
        daemons: any LeoPluginDaemonAccess, confirmer: any LeoPluginConfirming, effects: any LeoPluginActionEffects,
        slots: LeoPluginSlotStore
    ) {
        self.daemons = daemons
        self.confirmer = confirmer
        self.effects = effects
        self.slots = slots
    }

    // MARK: LeoPluginActionRunning

    public func perform(_ action: LeoPluginAction, plugin: LeoPluginIdentity, slot: LeoPluginSlotID?) {
        switch action {
        case .copy(let text):
            effects.copy(text)
        case .openURL(let raw):
            // The gate checked already; a second look costs nothing.
            guard let url = Self.httpsURL(raw) else { return effects.report(plugin: plugin, message: "Refused to open a link that isn't a plain https URL.") }
            effects.open(url)
        case .pushView(let node):
            guard let slot else { return }
            slots.push(node, onto: LeoPluginSlotKey(pluginID: plugin.id, slot: slot))
        case .callback, .sendToAgent, .spawnAgent:
            // Callbacks are the manager's; send and spawn only through `confirm`.
            break
        }
    }

    public func confirm(_ action: LeoPluginAction, plugin: LeoPluginIdentity) {
        guard pending[plugin.id, default: [:]].count < Self.maxPendingConfirmations else {
            return effects.report(plugin: plugin, message: "Too many requests from \(plugin.name) are waiting for you. Answer them first.")
        }
        let token = UUID()
        let generation = generation(of: plugin.id)
        pending[plugin.id, default: [:]][token] = Task { [weak self] in
            await self?.run(.confirm(action), plugin: plugin, generation: generation)
            self?.pending[plugin.id]?[token] = nil
        }
    }

    public func cancelPending(pluginID: String) {
        generations[pluginID] = generation(of: pluginID) + 1
        let tasks = pending.removeValue(forKey: pluginID) ?? [:]
        tasks.values.forEach { $0.cancel() }
    }

    /// Runs one authorized action to completion (the sheet, then the daemon call).
    public func run(_ authorized: LeoPluginAuthorizedAction, plugin: LeoPluginIdentity) async {
        await run(authorized, plugin: plugin, generation: generation(of: plugin.id))
    }

    private func run(_ authorized: LeoPluginAuthorizedAction, plugin: LeoPluginIdentity, generation: Int) async {
        guard isLive(plugin, generation) else { return }
        switch authorized {
        case .perform(let action): perform(action, plugin: plugin, slot: nil)
        case .confirm(.sendToAgent(let agent, let text)): await send(text: text, to: agent, plugin: plugin, generation: generation)
        case .confirm(.spawnAgent(let spec)): await spawn(spec, plugin: plugin, generation: generation)
        case .confirm: break
        }
    }

    private func generation(of pluginID: String) -> Int { generations[pluginID, default: 0] }

    /// The plugin hasn't been stopped, disabled or removed since this run began.
    private func isLive(_ plugin: LeoPluginIdentity, _ generation: Int) -> Bool {
        generation == self.generation(of: plugin.id) && !Task.isCancelled
    }

    // MARK: Send

    private func send(text: String, to agent: LeoPluginAgentRef, plugin: LeoPluginIdentity, generation: Int) async {
        guard text.utf8.count <= Self.maxTextBytes else {
            return effects.report(plugin: plugin, message: "\(plugin.name) tried to send a message that is too long.")
        }
        let draft = LeoPluginSendDraft(pluginName: plugin.name, agent: agent, text: text)
        guard let edited = await confirmer.confirmSend(draft), isLive(plugin, generation) else { return }
        guard edited.utf8.count <= Self.maxTextBytes else {
            return effects.report(plugin: plugin, message: "That message is too long to send.")
        }
        guard let commands = daemons.commands(forMachine: agent.machine) else {
            return effects.report(plugin: plugin, message: "Not connected to \(agent.machine), so the message to \(agent.name) wasn't sent.")
        }
        do {
            try await commands.message(agent.name, text: edited)
        } catch {
            effects.report(plugin: plugin, message: "Couldn't send the message to \(agent.name): \(error.localizedDescription)")
        }
    }

    // MARK: Spawn

    private func spawn(_ proposed: LeoPluginSpawnSpec, plugin: LeoPluginIdentity, generation: Int) async {
        guard proposed.prompt.utf8.count <= Self.maxTextBytes else {
            return effects.report(plugin: plugin, message: "\(plugin.name) tried to start an agent with a prompt that is too long.")
        }
        let machines = daemons.machines
        let machine = proposed.machine.flatMap { machines.contains($0) ? $0 : nil } ?? daemons.defaultMachine
        let spec = LeoPluginSpawnSpec(
            repo: proposed.repo, branch: proposed.branch, base: proposed.base, prompt: proposed.prompt, machine: machine,
            template: proposed.template)
        guard let edited = await confirmer.confirmSpawn(LeoPluginSpawnDraft(pluginName: plugin.name, spec: spec, machines: machines)),
            isLive(plugin, generation)
        else { return }

        let repo = edited.repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = edited.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty, !branch.isEmpty, edited.prompt.utf8.count <= Self.maxTextBytes else {
            return effects.report(plugin: plugin, message: "An agent needs a repository and a branch, and a prompt under \(Self.maxTextBytes / 1024) KB.")
        }
        guard let template = edited.template?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty else {
            return effects.report(plugin: plugin, message: "An agent needs a template. Choose one in the sheet.")
        }
        let target = edited.machine ?? machine
        guard let commands = daemons.commands(forMachine: target) else {
            return effects.report(plugin: plugin, message: "Not connected to \(target), so the agent wasn't started.")
        }
        let base = edited.base?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = LeoSpawnRequest(template: template, repo: repo, branch: branch, base: (base ?? "").isEmpty ? nil : base, prompt: edited.prompt)
        do {
            try await commands.spawn(request)
        } catch {
            effects.report(plugin: plugin, message: "Couldn't start the agent: \(error.localizedDescription)")
        }
    }

    private static func httpsURL(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
            let host = components.host, !host.isEmpty, components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }
}
