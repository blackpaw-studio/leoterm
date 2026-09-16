import Foundation

/// What the agent palette resolved to when the user confirmed a row (or
/// cancelled). Pure value type -- no AppKit, no routing behaviour.
enum LeoPickerChoice: Equatable {
    case agent(LeoAgentIdentity)
    case newAgent
    case plainShell
    case cancel
}
