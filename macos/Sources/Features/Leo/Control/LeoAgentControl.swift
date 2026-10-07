import Foundation

/// The four operator control verbs on `POST /agents/{name}/<verb>` (B-262).
enum LeoControlVerb: String, CaseIterable, Sendable {
    case message, interrupt, compact, clear
}

/// How the daemon took a message: handed to the agent now, or queued for
/// when it can (a 202).
enum LeoMessageDelivery: Equatable, Sendable {
    case delivered(transport: String?)
    case queued
}
