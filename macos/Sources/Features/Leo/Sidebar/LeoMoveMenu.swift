import AppKit
import SwiftUI
import LeoKit

/// One line of a Move To or Copy To submenu.
enum LeoMoveMenuEntry: Equatable {
    case host(String)
    case placeholder(String)
}

/// The wording and entries of B-324's Move To, Copy To and Duplicate…, shared
/// by the sidebar row's context menu and the Agents menu so the two read alike.
enum LeoMoveMenu {
    static let moveTitle = "Move To"
    static let copyTitle = "Copy To"
    static let duplicateTitle = "Duplicate…"
    static let confirmDetail = "It stops here and resumes there."

    /// `destinations` is nil until the host's list has loaded.
    static func entries(_ destinations: LeoMoveDestinations?) -> [LeoMoveMenuEntry] {
        switch destinations {
        case nil: [.placeholder("Loading…")]
        case .unavailable?: [.placeholder("Unavailable")]
        case .hosts(let hosts)? where hosts.isEmpty: [.placeholder("No Other Machines")]
        case .hosts(let hosts)?: hosts.map(LeoMoveMenuEntry.host)
        }
    }

    static func confirmMessage(agent: String, host: String) -> String { "Move \(agent) to \(host)?" }
}

/// The alerts for a move: asking first, and asking again when the agent is
/// mid-turn.
@MainActor enum LeoMoveConfirmation {
    static let moveTitle = "Move"
    static let forceTitle = "Move Anyway"
    static let cancelTitle = "Cancel"

    static func makeMoveAlert(agent: String, host: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = LeoMoveMenu.confirmMessage(agent: agent, host: host)
        alert.informativeText = LeoMoveMenu.confirmDetail
        alert.addButton(withTitle: moveTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert
    }

    /// The daemon's reason, with the choice to move the agent mid-turn anyway.
    static func makeForceAlert(_ offer: LeoMoveForceOffer) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(offer.row.name) is busy"
        alert.informativeText = offer.message
        alert.addButton(withTitle: cancelTitle)
        let force = alert.addButton(withTitle: forceTitle)
        force.hasDestructiveAction = true
        return alert
    }

    static func confirmMove(agent: String, host: String, in window: NSWindow?) async -> Bool {
        await run(makeMoveAlert(agent: agent, host: host), in: window) == .alertFirstButtonReturn
    }

    static func confirmForce(_ offer: LeoMoveForceOffer, in window: NSWindow?) async -> Bool {
        await run(makeForceAlert(offer), in: window) == .alertSecondButtonReturn
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await alert.beginSheetModal(for: window)
    }
}

/// What picking Move To, Copy To or Duplicate… does, from either menu.
@MainActor enum LeoMoveFlow {
    static func move(_ row: LeoAgentRow, to host: String, actions: LeoAgentActions, in window: NSWindow?) {
        Task { @MainActor in
            guard await LeoMoveConfirmation.confirmMove(agent: row.name, host: host, in: window) else { return }
            actions.move(row, to: host)
        }
    }

    /// Copy and Duplicate (no `host`) ask for the copy's optional name first.
    static func copy(_ row: LeoAgentRow, to host: String?, actions: LeoAgentActions, in window: NSWindow?) {
        window?.presentLeoSheet(NSHostingController(rootView: LeoCopyAgentSheet(row: row, destination: host, actions: actions)))
    }

    /// Asks about a mid-turn refusal as it is published. Wired by `LeoRuntime`.
    static func offerForce(_ offer: LeoMoveForceOffer, actions: LeoAgentActions, in window: NSWindow?) {
        Task { @MainActor in
            if await LeoMoveConfirmation.confirmForce(offer, in: window) {
                actions.acceptForceOffer()
            } else {
                actions.dismissForceOffer()
            }
        }
    }
}
