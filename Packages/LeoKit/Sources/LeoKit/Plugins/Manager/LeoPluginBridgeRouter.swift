import Foundation
import OSLog

/// Answers one plugin host session's bridge requests.
///
/// One router per host process, living on the main actor, so every request
/// from a plugin is handled on one actor in the order it arrived. It checks
/// each request against the manifest and the approved permissions, then calls
/// the matching service. It owns the live callback records (see
/// `LeoPluginCallbackRegistry`) and never trusts anything in a message beyond
/// the fields it decodes: authority comes from its own records.
@MainActor public final class LeoPluginBridgeRouter {
    /// Everything the router talks to. All injected.
    public struct Dependencies {
        public let identity: LeoPluginIdentity
        public let manifest: LeoPluginManifest
        public let engine: LeoPluginPermissionEngine
        public let gate: LeoPluginActionGate
        public let fetcher: any LeoPluginFetching
        public let secrets: LeoPluginSecrets?
        public let timers: LeoPluginTimers
        public let slots: LeoPluginSlotStore
        public let actions: any LeoPluginActionRunning
        public let agents: @MainActor () -> [(LeoHostID, LeoAgent)]
        public let now: @Sendable () -> Date
        /// Delivers an event to this session's host (replies).
        public let send: @MainActor (LeoPluginEvent) -> Void

        public init(
            identity: LeoPluginIdentity, manifest: LeoPluginManifest, engine: LeoPluginPermissionEngine,
            gate: LeoPluginActionGate, fetcher: any LeoPluginFetching, secrets: LeoPluginSecrets?, timers: LeoPluginTimers,
            slots: LeoPluginSlotStore, actions: any LeoPluginActionRunning,
            agents: @escaping @MainActor () -> [(LeoHostID, LeoAgent)], now: @escaping @Sendable () -> Date,
            send: @escaping @MainActor (LeoPluginEvent) -> Void
        ) {
            self.identity = identity
            self.manifest = manifest
            self.engine = engine
            self.gate = gate
            self.fetcher = fetcher
            self.secrets = secrets
            self.timers = timers
            self.slots = slots
            self.actions = actions
            self.agents = agents
            self.now = now
            self.send = send
        }
    }

    public static let maxTimerIDLength = 64
    static let maxLogBytes = 2048

    private static let logger = LeoLog.logger(category: "leo.plugins")

    private let deps: Dependencies
    private var callbacks = LeoPluginCallbackRegistry()
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    public init(_ dependencies: Dependencies) {
        deps = dependencies
    }

    /// Whether a `fetch` is still waiting for its reply.
    public var hasPendingFetches: Bool { !inFlight.isEmpty }

    /// The session ended: drop live callbacks and cancel pending work, and ignore anything still queued.
    public func close() {
        isClosed = true
        callbacks.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    // MARK: Callbacks

    /// The `callback` event for a click or key press. The ref in it is what a
    /// follow-up must quote; `gesture` and `slot` stay here, never in the event.
    public func callbackEvent(
        id: String, payload: LeoJSONValue, gesture: LeoPluginGesture?, slot: LeoPluginSlotID?
    ) -> LeoPluginEvent {
        let ref = callbacks.register(gesture: gesture, slot: slot, now: deps.now())
        return .callback(ref: ref, id: id, payload: payload, gesture: gesture != nil)
    }

    // MARK: Requests

    public func handle(_ request: LeoPluginHostRequest) {
        guard !isClosed else { return }
        switch request {
        case .render(let slot, let node): render(slot: slot, node: node)
        case .fetch(let id, let url, let options): fetch(id: id, url: url, options: options)
        case .secretsGet(let id, let key): reply(id) { try self.requireSecrets().get(key: key).map(LeoJSONValue.string) ?? .null }
        case .secretsSet(let id, let key, let value):
            reply(id) {
                try self.requireSecrets().set(key: key, value: value)
                return .null
            }
        case .secretsDelete(let id, let key):
            reply(id) {
                try self.requireSecrets().delete(key: key)
                return .null
            }
        case .agentsList(let id):
            reply(id) { try LeoPluginAgentsSnapshot.value(agents: self.deps.agents(), engine: self.deps.engine) }
        case .timerStart(let id, let seconds): startTimer(id: id) { try self.deps.timers.startPeriodic(id: id, seconds: seconds) }
        case .afterStart(let id, let seconds): startTimer(id: id) { try self.deps.timers.startAfter(id: id, seconds: seconds) }
        case .timerStop(let id): deps.timers.stop(id: id)
        case .log(let level, let message): log(level: level, message: message)
        case .callbackResult(let ref, let action): followUp(ref: ref, action: action)
        case .handlerError(let source, let message): handlerError(source: source, message: message)
        case .unsupported(let call): warn("unsupported bridge call '\(Self.clip(call, 64))'")
        }
    }

    // MARK: Render

    private func render(slot: LeoPluginSlotID, node: LeoPluginSlotRoot) {
        guard declares(slot) else {
            warn("render refused: the manifest declares no contribution for slot \(Self.clip(slot.key, 120))")
            return
        }
        if !deps.slots.render(pluginID: deps.identity.id, slot: slot, root: node) {
            warn("render refused: too many slots")
        }
    }

    private func declares(_ slot: LeoPluginSlotID) -> Bool {
        let contributes = deps.manifest.contributes
        switch slot {
        case .view(let id, _): return contributes.views.contains { $0.id == id }
        case .accessory(let id, _): return contributes.rowAccessories.contains { $0.id == id }
        case .section(let id): return contributes.sidebarSections.contains { $0.id == id }
        case .palette(let id): return contributes.commands.contains { $0.id == id }
        }
    }

    // MARK: Services

    private func fetch(id: String, url: String, options: LeoPluginFetchInit) {
        let taskID = UUID()
        let fetcher = deps.fetcher
        inFlight[taskID] = Task { [weak self] in
            let outcome: LeoPluginReplyOutcome
            do {
                outcome = .value(try await fetcher.fetch(url: url, init: options).replyValue)
            } catch {
                outcome = .rejected(reason: (error as? LeoPluginFetchError)?.reason ?? error.localizedDescription)
            }
            guard let self, !self.isClosed, !Task.isCancelled else { return }
            self.inFlight[taskID] = nil
            self.deps.send(.reply(id: id, outcome: outcome))
        }
    }

    /// Runs a synchronous service call and answers request `id`.
    private func reply(_ id: String, _ body: () throws -> LeoJSONValue) {
        let outcome: LeoPluginReplyOutcome
        do {
            outcome = .value(try body())
        } catch {
            outcome = .rejected(reason: error.localizedDescription)
        }
        deps.send(.reply(id: id, outcome: outcome))
    }

    private func requireSecrets() throws -> LeoPluginSecrets {
        guard let secrets = deps.secrets else { throw LeoPluginSecretsError.permissionDenied("secrets are unavailable") }
        return secrets
    }

    private func startTimer(id: String, _ start: () throws -> Void) {
        guard id.utf8.count <= Self.maxTimerIDLength else { return warn("timer refused: id is too long") }
        do { try start() } catch { warn("timer refused: \(error.localizedDescription)") }
    }

    // MARK: Follow-ups

    /// A callback handler's one follow-up. The ref must be a live record this
    /// session created; the gesture comes from that record, never from the message.
    private func followUp(ref: String, action: LeoPluginAction) {
        guard let record = callbacks.redeem(ref, now: deps.now()) else {
            return warn("follow-up dropped: unknown, used or expired callback")
        }
        let decision = deps.gate.authorizeFollowUp(action, originGesture: record.gesture)
        switch decision {
        case .failure(let refusal):
            warn("follow-up refused: \(refusal)")
        case .success(.confirm(let confirmed)):
            deps.actions.confirm(confirmed, plugin: deps.identity)
        case .success(.perform(let performed)):
            // A callback that resolves to a callback could ping-pong with the host
            // forever without any gesture; there is nothing it could do that the
            // handler couldn't do itself.
            if case .callback = performed { return warn("follow-up dropped: a callback can't resolve to a callback") }
            deps.actions.perform(performed, plugin: deps.identity, slot: record.slot)
        }
    }

    // MARK: Diagnostics

    private func log(level: String, message: String) {
        let text = Self.clip(message, Self.maxLogBytes)
        let id = deps.identity.id
        switch level.lowercased() {
        case "error": Self.logger.error("[\(id, privacy: .public)] \(text, privacy: .private)")
        case "warn", "warning": Self.logger.warning("[\(id, privacy: .public)] \(text, privacy: .private)")
        default: Self.logger.info("[\(id, privacy: .public)] \(text, privacy: .private)")
        }
    }

    private func handlerError(source: String, message: String) {
        let text = Self.clip(message, 300)
        Self.logger.error("[\(self.deps.identity.id, privacy: .public)] \(Self.clip(source, 32), privacy: .public) handler failed: \(text, privacy: .private)")
        deps.slots.failLoadingSlots(pluginID: deps.identity.id, message: text)
    }

    private func warn(_ message: String) {
        Self.logger.warning("[\(self.deps.identity.id, privacy: .public)] \(message, privacy: .public)")
    }

    private static func clip(_ text: String, _ bytes: Int) -> String {
        text.utf8.count <= bytes ? text : String(decoding: Array(text.utf8.prefix(bytes)), as: UTF8.self)
    }
}
