import ComposableArchitecture
import Foundation
import LeoKit

/// One agent's browser pane on iPhone (B-305), pushed from the agent's
/// detail. The page, its tabs and its bars live in the app's WebKit
/// browser; this feature carries the user's control decisions to it:
/// Done or Decline on a handoff, Hand Back, and Take Control.
@Reducer
public struct AgentBrowser {
    @ObservableState
    public struct State: Equatable {
        public let agent: AgentRef
        /// The daemon's name, for "<machine>'s localhost".
        public let machineName: String
        public let displayName: String

        public init(agent: AgentRef, machineName: String, displayName: String) {
            self.agent = agent
            self.machineName = machineName
            self.displayName = displayName
        }
    }

    public enum Action: Equatable {
        /// The handoff bar's Done: the agent's `browser_handoff` returns `done`.
        case handoffDoneTapped(requestID: String)
        /// The handoff bar's Decline: the call returns `declined`.
        case handoffDeclineTapped(requestID: String)
        /// The Hand Back pill: the agent drives again.
        case handBackTapped
        /// Take Control in the More menu, for a user who wants the page held
        /// without touching it first.
        case takeControlTapped
    }

    @Dependency(\.clientTools) var clientTools

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            let event: LeoBrowserControl.Event = switch action {
            case .handoffDoneTapped(let requestID): .done(requestID: requestID)
            case .handoffDeclineTapped(let requestID): .decline(requestID: requestID)
            case .handBackTapped: .giveBack
            case .takeControlTapped: .pill
            }
            let (agent, clientTools) = (state.agent, clientTools)
            return .run { _ in await clientTools.control(agent, event) }
        }
    }
}
