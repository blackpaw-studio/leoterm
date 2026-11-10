import Foundation

/// Agent verbs a plugin's manifest can grant (`permissions.agents`).
///
/// Defined here so the gate stands alone; the manifest type from step 1.1
/// should conform to `LeoPluginAgentGrants` instead of redefining this.
public enum LeoPluginAgentVerb: String, Codable, Sendable {
    case read, send, spawn
}

public protocol LeoPluginAgentGrants: Sendable {
    func allows(_ verb: LeoPluginAgentVerb) -> Bool
}

extension Set: LeoPluginAgentGrants where Element == LeoPluginAgentVerb {
    public func allows(_ verb: LeoPluginAgentVerb) -> Bool { contains(verb) }
}

/// Proof that a person just clicked or pressed a key on an action.
///
/// Only the native renderers' click and keyboard paths create one. It is
/// deliberately neither `Codable` nor reachable from the bridge: nothing
/// decoded from plugin output can be a gesture, and the host only ever sees
/// a boolean "this callback came from a gesture" flag.
public struct LeoPluginGesture: Equatable, Sendable {
    public enum Origin: Sendable { case click, keyboard }

    public let id: UUID
    public let origin: Origin
    public let mintedAt: Date

    public init(origin: Origin, mintedAt: Date, id: UUID = UUID()) {
        self.id = id
        self.origin = origin
        self.mintedAt = mintedAt
    }
}

public enum LeoPluginActionRefusal: Error, Equatable, Sendable {
    case missingGesture
    case expiredGesture
    case gestureAlreadyUsed
    case permissionDenied(LeoPluginAgentVerb)
    case insecureURL
    case invalidTarget
}

/// What the app may do with an action that passed the gate.
public enum LeoPluginAuthorizedAction: Equatable, Sendable {
    /// Safe to carry out directly (callback, pushView, copy, https openURL).
    case perform(LeoPluginAction)
    /// Send or spawn: the executor must open the confirmation sheet and
    /// call the daemon only after the person confirms.
    case confirm(LeoPluginAction)
}

/// Per-plugin gate between plugin-supplied actions and anything with a side
/// effect. `sendToAgent` and `spawnAgent` pass only with the manifest
/// permission *and* a live, unused `LeoPluginGesture`, and even then only
/// as `.confirm`, never `.perform`.
public final class LeoPluginActionGate: @unchecked Sendable {
    /// A gesture, and a follow-up resolved from it, stay valid this long.
    public static let gestureLifetime: TimeInterval = 30

    private let grants: any LeoPluginAgentGrants
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var consumed: [UUID: Date] = [:]

    public init(grants: any LeoPluginAgentGrants, now: @escaping @Sendable () -> Date) {
        self.grants = grants
        self.now = now
    }

    /// A direct action from a renderer. `gesture` is the click or key press
    /// that triggered it, when there was one.
    public func authorize(
        _ action: LeoPluginAction, gesture: LeoPluginGesture?
    ) -> Result<LeoPluginAuthorizedAction, LeoPluginActionRefusal> {
        switch action {
        case .callback, .pushView, .copy:
            return .success(.perform(action))
        case .openURL(let raw):
            return Self.isAllowedURL(raw) ? .success(.perform(action)) : .failure(.insecureURL)
        case .sendToAgent, .spawnAgent:
            return authorizeAgentAction(action, gesture: gesture)
        }
    }

    /// The single action a callback handler resolved to. Honoured only when
    /// the callback started with a gesture that is still within the window;
    /// consumes that gesture, so a callback yields one follow-up at most.
    public func authorizeFollowUp(
        _ action: LeoPluginAction, originGesture: LeoPluginGesture?
    ) -> Result<LeoPluginAuthorizedAction, LeoPluginActionRefusal> {
        let decision: Result<LeoPluginAuthorizedAction, LeoPluginActionRefusal>
        switch action {
        case .sendToAgent, .spawnAgent:
            decision = authorizeAgentAction(action, gesture: originGesture, consume: false)
        default:
            decision = authorize(action, gesture: nil)
        }
        guard case .success = decision else { return decision }
        // Even a harmless follow-up needs a live gesture, and uses it up.
        if case .failure(let refusal) = redeem(originGesture) { return .failure(refusal) }
        return decision
    }

    // MARK: Private

    private func authorizeAgentAction(
        _ action: LeoPluginAction, gesture: LeoPluginGesture?, consume: Bool = true
    ) -> Result<LeoPluginAuthorizedAction, LeoPluginActionRefusal> {
        guard Self.hasValidTarget(action) else { return .failure(.invalidTarget) }
        let verb: LeoPluginAgentVerb
        if case .spawnAgent = action { verb = .spawn } else { verb = .send }
        guard grants.allows(verb) else { return .failure(.permissionDenied(verb)) }
        if consume {
            if case .failure(let refusal) = redeem(gesture) { return .failure(refusal) }
        } else if case .failure(let refusal) = check(gesture) {
            return .failure(refusal)
        }
        return .success(.confirm(action))
    }

    /// Validates without consuming.
    private func check(_ gesture: LeoPluginGesture?) -> Result<Void, LeoPluginActionRefusal> {
        guard let gesture else { return .failure(.missingGesture) }
        let current = now()
        guard current.timeIntervalSince(gesture.mintedAt) <= Self.gestureLifetime else {
            return .failure(.expiredGesture)
        }
        lock.lock()
        defer { lock.unlock() }
        return consumed[gesture.id] == nil ? .success(()) : .failure(.gestureAlreadyUsed)
    }

    /// Validates and marks the gesture used.
    private func redeem(_ gesture: LeoPluginGesture?) -> Result<Void, LeoPluginActionRefusal> {
        if case .failure(let refusal) = check(gesture) { return .failure(refusal) }
        guard let gesture else { return .failure(.missingGesture) }
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        consumed = consumed.filter { current.timeIntervalSince($0.value) <= Self.gestureLifetime }
        consumed[gesture.id] = gesture.mintedAt
        return .success(())
    }

    private static func hasValidTarget(_ action: LeoPluginAction) -> Bool {
        switch action {
        case .sendToAgent(let agent, _):
            return !agent.name.isEmpty && !agent.machine.isEmpty
        case .spawnAgent(let spec):
            return !spec.repo.isEmpty && !spec.branch.isEmpty
        default:
            return true
        }
    }

    private static func isAllowedURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return false }
        return true
    }
}
