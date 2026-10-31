import ComposableArchitecture
import Foundation
import LeoKit

/// The root tab bar's tabs, in display order.
public enum AppTab: Int, CaseIterable, Equatable, Sendable {
    case chats, agents, machines, settings
}

extension AppFeature.State {
    /// What `daemonID`'s agents' Move menus offer.
    public func moveAvailability(for daemonID: DaemonSession.ID) -> MoveAvailability {
        MoveAvailability(supportsMove: fleet.sessions[id: daemonID]?.supportsMove == true, destinations: moveDestinations[daemonID])
    }

    /// Opens the move flow for `ref`, unless a flow is already open (its
    /// result would otherwise land on the wrong agent), its daemon can't move
    /// agents or the agent already lives elsewhere.
    mutating func openMove(_ ref: AgentRef, _ intent: AgentMove.Intent) {
        guard move == nil, let session = fleet.sessions[id: ref.daemonID], session.supportsMove,
              let agent = session.agents[id: ref.name], agent.canMove else { return }
        move = AgentMove.State(daemon: session.daemon, agentName: ref.name, intent: intent)
    }

    /// Opens a tapped notification's agent as soon as its daemon has
    /// reported it; gives up once the paired daemons are known and its
    /// daemon isn't one, or the daemon is connected and the agent is gone.
    mutating func openPendingAgent() {
        guard let ref = pendingAgent else { return }
        guard let session = fleet.sessions[id: ref.daemonID] else {
            if hasLoadedDaemons { pendingAgent = nil }
            return
        }
        if let agent = session.agents[id: ref.name] {
            pendingAgent = nil
            selectAgent(ref, session: session, agent: agent)
        } else if session.connection.isConnected {
            pendingAgent = nil
        }
    }

    /// Whether `ref`'s thread is the one on screen (its banners are
    /// suppressed and its messages count as read).
    public func isChatOnScreen(_ ref: AgentRef) -> Bool {
        chat?.ref == ref && chat?.isOnScreen == true
    }

    /// Selects `ref`'s agent detail; the open chat is the Chats tab's and stays.
    mutating func selectAgent(_ ref: AgentRef, session: DaemonSession, agent: Agent) {
        guard detail?.ref != ref else { return }
        detail = AgentDetail.State(daemon: session.daemon, agent: agent, connection: session.connection)
    }

    /// Switches to the Chats tab and shows `ref`'s thread there.
    mutating func openChat(_ ref: AgentRef) {
        guard let session = fleet.sessions[id: ref.daemonID] else { return }
        selectedTab = .chats
        pendingChat = nil
        pendingAgent = nil
        chats.unreadCounts = chats.unreadCounts.clearing(ref.leoAgentID)
        guard chat?.ref != ref else { return }
        parkChatDrafts()
        var thread = ChatThread.State(daemon: session.daemon, agent: ref.name, live: session.agents[id: ref.name])
        thread.questionsDrafts = parkedQuestionsDrafts.removeValue(forKey: ref) ?? [:]
        chat = thread
    }

    /// Sets the open thread's unsent questions answers aside before it is replaced.
    mutating func parkChatDrafts() {
        guard let thread = chat, !thread.questionsDrafts.isEmpty else { return }
        parkedQuestionsDrafts[thread.ref] = thread.questionsDrafts
    }

    /// Opens a tapped chat notification's thread once its daemon is known;
    /// gives up when the paired daemons are loaded and it isn't one.
    mutating func openPendingChat() {
        guard let ref = pendingChat else { return }
        if fleet.sessions[id: ref.daemonID] != nil {
            openChat(ref)
        } else if hasLoadedDaemons {
            pendingChat = nil
        }
    }

    /// Picks the inbox's first chip once the fleet has settled: Needs you when
    /// something does, otherwise All. After that only the user changes it.
    mutating func decideChatFilter() {
        guard chats.filter == nil, hasLoadedDaemons else { return }
        let isSettled = fleet.sessions.allSatisfy { session in
            switch session.connection {
            case .offline, .connecting: false
            case .connected, .reconnecting, .unauthorized: true
            }
        }
        guard isSettled else { return }
        let rows = ChatList.rows(threads: chats.threads, unread: chats.unreadCounts, sessions: fleet.sessions)
        chats.filter = ChatList.counts(rows).needsYou > 0 ? .needsYou : .all
    }

    /// Keeps the open thread's agent and daemon in step with the fleet.
    mutating func syncChat() {
        guard let ref = chat?.ref, let session = fleet.sessions[id: ref.daemonID] else { return }
        let agent = session.agents[id: ref.name]
        if chat?.agent != agent { chat?.agent = agent }
        if chat?.daemon != session.daemon { chat?.daemon = session.daemon }
    }

    /// The open machine's settings follow the fleet through an action, so the
    /// settings can tell a pane that its machine reconnected.
    func machineLinkUpdate() -> Effect<AppFeature.Action> {
        guard let machine = daemons.machine, let session = fleet.sessions[id: machine.id] else { return .none }
        let link = MachineLink(session: session)
        return link == machine.link ? .none : .send(.daemons(.machine(.presented(.linkUpdated(link)))))
    }

    /// A terminal opens and closes its socket as its agent starts and stops,
    /// so that change reaches it as an action, not a state edit.
    func terminalRunningUpdates() -> Effect<AppFeature.Action> {
        var updates: [Effect<AppFeature.Action>] = []
        if let terminal = detail?.destination?.terminal, let agent = detail?.agent, terminal.isAgentRunning == agent.isStopped {
            updates.append(.send(.detail(.destination(.presented(.terminal(.agentRunningChanged(!agent.isStopped)))))))
        }
        if let terminal = chat?.terminal, let agent = chat?.agent, terminal.isAgentRunning != agent.canOpenTerminal {
            updates.append(.send(.chat(.terminal(.presented(.agentRunningChanged(agent.canOpenTerminal))))))
        }
        return .merge(updates)
    }

    /// Keeps the open detail in step with the live fleet.
    mutating func syncDetail() {
        guard let ref = detail?.ref, let session = fleet.sessions[id: ref.daemonID] else { return }
        let agent = session.agents[id: ref.name]
        if detail?.agent != agent { detail?.agent = agent }
        if detail?.connection != session.connection { detail?.connection = session.connection }
        if detail?.daemon != session.daemon { detail?.daemon = session.daemon }
        let moves = moveAvailability(for: ref.daemonID)
        if detail?.moves != moves { detail?.moves = moves }
    }

    /// Keeps the open Appearance sheet in step with the live fleet.
    mutating func syncAppearance() {
        guard let sheet = appearance, let session = fleet.sessions[id: sheet.daemon.id] else { return }
        let agent = session.agents[id: sheet.agentName]
        // Only a change in the fleet's value: its stale one must not undo a write's answer.
        if let agent, agent.appearance != sheet.fleetAppearance {
            appearance?.fleetAppearance = agent.appearance
            appearance?.receive(agent.appearance)
        }
        if sheet.daemon != session.daemon { appearance?.daemon = session.daemon }
    }
}
