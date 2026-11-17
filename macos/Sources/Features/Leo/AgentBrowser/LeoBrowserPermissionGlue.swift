import LeoKit
import WebKit

extension LeoBrowserSite {
    /// The site of a WebKit security origin (its port is 0 for the default).
    init(_ origin: WKSecurityOrigin) {
        self.init(scheme: origin.protocol, host: origin.host, port: origin.port)
    }
}

extension LeoBrowserPermissionKind {
    /// nil for a capture type this build doesn't know: it is denied.
    init?(_ type: WKMediaCaptureType) {
        switch type {
        case .camera: self = .camera
        case .microphone: self = .microphone
        case .cameraAndMicrophone: self = .cameraAndMicrophone
        @unknown default: return nil
        }
    }
}

/// What the pane's permission bar shows (B-410): which agent's page asks,
/// from which site, for what. The site is in the agent's (remote) terms,
/// as the address bar shows it.
struct LeoBrowserPermissionPrompt: Equatable {
    /// Tells this ask from a later one for the same thing, so an answer
    /// meant for a withdrawn ask never answers the next.
    let id: Int
    let agent: String
    let request: LeoBrowserPermissionRequest

    /// "alfred · meet.example.com:8443 wants to use your camera".
    var message: String {
        LeoBrowserRequestText.message(agent: agent, origin: request.site.label, wants: "use \(request.kind.userNoun)")
    }

    static let detail = "Only you can answer. Your answer lasts until this tab closes."
}

/// One page's request waiting on the user. It answers the page's decision
/// handler exactly once, however it ends: WebKit raises if a handler is
/// dropped unanswered.
@MainActor final class LeoBrowserPermissionAsk {
    let id: Int
    let request: LeoBrowserPermissionRequest
    private var decide: (@MainActor (Bool) -> Void)?

    init(id: Int, request: LeoBrowserPermissionRequest, decide: @escaping @MainActor (Bool) -> Void) {
        self.id = id
        self.request = request
        self.decide = decide
    }

    func answer(_ allowed: Bool) {
        guard let decide else { return }
        self.decide = nil
        decide(allowed)
    }
}

/// An agent browser's permission requests (B-410): each tab's answers, and
/// the asks waiting on the user, oldest first. Only the active tab, shown
/// in a pane, ever has asks: a request from anywhere else is denied, and
/// an ask whose page leaves the pane is withdrawn.
@MainActor final class LeoBrowserPermissionDesk {
    /// Tells the tab's page why a request was denied.
    typealias Note = @MainActor (_ tab: Int, _ request: LeoBrowserPermissionRequest, _ denial: LeoBrowserPermissionDenial) -> Void

    private let note: Note
    private var ledgers: [Int: LeoBrowserPermissionLedger] = [:]
    private var asks: [Int: [LeoBrowserPermissionAsk]] = [:]
    private var nextID = 1

    init(note: @escaping Note) {
        self.note = note
    }

    /// The ask the user sees for `tab`, if any.
    func waiting(inTab tab: Int) -> LeoBrowserPermissionAsk? { asks[tab]?.first }

    /// Settles `request` from `tab` at once when it can (not shown, or
    /// already answered in this tab), else queues it for the user. True
    /// when it was queued.
    func receive(
        _ request: LeoBrowserPermissionRequest, inTab tab: Int, isShown: Bool, decide: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        let ask = LeoBrowserPermissionAsk(id: nextID, request: request, decide: decide)
        nextID += 1
        guard settle(ask, inTab: tab, isShown: isShown) else {
            asks[tab, default: []].append(ask)
            return true
        }
        return false
    }

    /// The user's answer to ask `id`, the one shown for `tab`. False (and
    /// nothing answered) when that ask is no longer the one shown. Asks
    /// queued behind it that the answer covers are settled too.
    func answer(_ id: Int, allow: Bool, inTab tab: Int) -> Bool {
        guard let ask = asks[tab]?.first, ask.id == id else { return false }
        asks[tab]?.removeFirst()
        ledgers[tab] = ledger(tab).remembering(ask.request, allowed: allow)
        if !allow { note(tab, ask.request, .user) }
        ask.answer(allow)
        while let next = asks[tab]?.first, settle(next, inTab: tab, isShown: true) {
            asks[tab]?.removeFirst()
        }
        if asks[tab]?.isEmpty == true { asks[tab] = nil }
        return true
    }

    /// Denies every ask `tab` has, without remembering it. A nil `reason`
    /// (the tab closed) leaves no console note: nobody can read it.
    @discardableResult
    func withdraw(inTab tab: Int, because reason: LeoBrowserPermissionDenial.Withdrawal?) -> Bool {
        guard let pending = asks.removeValue(forKey: tab) else { return false }
        for ask in pending {
            if let reason { note(tab, ask.request, .withdrawn(reason)) }
            ask.answer(false)
        }
        return true
    }

    /// Withdraws the asks of every tab but `active`: they left the pane.
    @discardableResult
    func withdraw(exceptTab active: Int?) -> Bool {
        let leaving = asks.keys.filter { $0 != active }
        return leaving.map { withdraw(inTab: $0, because: .tabSwitched) }.contains(true)
    }

    /// `tab` closed: its asks are denied and its answers go with it.
    func forget(tab: Int) {
        withdraw(inTab: tab, because: nil)
        ledgers[tab] = nil
    }

    private func ledger(_ tab: Int) -> LeoBrowserPermissionLedger { ledgers[tab] ?? LeoBrowserPermissionLedger() }

    /// Answers `ask` when the ledger can; false when it must wait on the user.
    private func settle(_ ask: LeoBrowserPermissionAsk, inTab tab: Int, isShown: Bool) -> Bool {
        switch ledger(tab).decision(for: ask.request, isShown: isShown) {
        case .allow:
            ask.answer(true)
        case .deny:
            note(tab, ask.request, isShown ? .remembered : .notShown)
            ask.answer(false)
        case .ask:
            return false
        }
        return true
    }
}
