import Foundation

/// What a page asked to use (B-410). Pages ask the human, never an agent.
public enum LeoBrowserPermissionKind: String, Sendable, CaseIterable {
    case camera
    case microphone
    case cameraAndMicrophone = "camera_and_microphone"
    case location

    /// The kinds an answer is remembered under: the pair is both of its parts.
    var parts: [Self] {
        self == .cameraAndMicrophone ? [.camera, .microphone] : [self]
    }

    /// For the person asked: "your camera", "your location".
    public var userNoun: String {
        switch self {
        case .camera: "your camera"
        case .microphone: "your microphone"
        case .cameraAndMicrophone: "your camera and microphone"
        case .location: "your location"
        }
    }

    /// For the agent: "the camera", "location".
    public var agentNoun: String {
        switch self {
        case .camera: "the camera"
        case .microphone: "the microphone"
        case .cameraAndMicrophone: "the camera and microphone"
        case .location: "location"
        }
    }
}

/// The site a request came from: scheme, host and port, compared without
/// case and with a scheme's default port the same as none.
public struct LeoBrowserPermissionSite: Hashable, Sendable {
    public let scheme: String
    /// Without IPv6 brackets.
    public let host: String
    /// nil for the scheme's default port.
    public let port: Int?

    private static let defaultPorts = ["http": 80, "https": 443]

    public init(scheme: String, host: String, port: Int?) {
        let scheme = scheme.lowercased()
        self.scheme = scheme
        self.host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = port == 0 || port == Self.defaultPorts[scheme] ? nil : port
    }

    /// The site of `url`'s origin; nil without a scheme.
    public init?(url: URL) {
        guard let scheme = url.scheme else { return nil }
        self.init(scheme: scheme, host: url.host(percentEncoded: false) ?? "", port: url.port)
    }

    /// `scheme://host[:port]`, as `url` would print it.
    public var origin: String { "\(scheme)://\(hostAndPort)" }

    /// The origin as a URL, for mapping between local and remote terms.
    public var url: URL? { URL(string: origin) }

    /// For people: the host plus a non-default port, or "this page" when
    /// there is no host (`about:blank`).
    public var label: String {
        host.isEmpty ? LeoBrowserRequestText.noHost : hostAndPort
    }

    private var hostAndPort: String {
        let host = self.host.contains(":") ? "[\(self.host)]" : self.host
        return port.map { "\(host):\($0)" } ?? host
    }
}

/// One page's request: what it wants, from which site.
public struct LeoBrowserPermissionRequest: Hashable, Sendable {
    public let kind: LeoBrowserPermissionKind
    public let site: LeoBrowserPermissionSite

    public init(kind: LeoBrowserPermissionKind, site: LeoBrowserPermissionSite) {
        self.kind = kind
        self.site = site
    }
}

/// One tab's answers, kept for the tab's life. Only the user's own answers
/// go in: an automatic deny (the tab wasn't on screen) or a withdrawn ask
/// is not an answer.
public struct LeoBrowserPermissionLedger: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case allow, deny, ask
    }

    private struct Key: Hashable, Sendable {
        let kind: LeoBrowserPermissionKind
        let site: LeoBrowserPermissionSite
    }

    private let answers: [Key: Bool]

    public init() {
        answers = [:]
    }

    private init(answers: [Key: Bool]) {
        self.answers = answers
    }

    /// Deny when the tab isn't on screen; otherwise the remembered answer,
    /// or ask. The pair needs both parts allowed, and either part denied
    /// denies it.
    public func decision(for request: LeoBrowserPermissionRequest, isShown: Bool) -> Decision {
        guard isShown else { return .deny }
        let known = request.kind.parts.map { answers[Key(kind: $0, site: request.site)] }
        if known.contains(false) { return .deny }
        return known.allSatisfy { $0 == true } ? .allow : .ask
    }

    /// This ledger with the user's answer to `request` (each part, for the pair).
    public func remembering(_ request: LeoBrowserPermissionRequest, allowed: Bool) -> Self {
        let added = request.kind.parts.map { (Key(kind: $0, site: request.site), allowed) }
        return Self(answers: answers.merging(added) { _, new in new })
    }
}

/// Why a request was denied, for the `permission_denied` console line.
public enum LeoBrowserPermissionDenial: Equatable, Sendable {
    /// The browser pane wasn't showing the tab, so nobody was asked.
    case notShown
    /// The user pressed Don't Allow.
    case user
    /// The user pressed Don't Allow earlier in this tab.
    case remembered
    /// The ask left the screen before the user answered.
    case withdrawn(Withdrawal)

    public enum Withdrawal: Equatable, Sendable {
        case tabSwitched, paneHidden, navigated, pageStopped

        var reason: String {
            switch self {
            case .tabSwitched: "another tab was made active"
            case .paneHidden: "the browser pane stopped showing this tab"
            case .navigated: "the page navigated away"
            case .pageStopped: "the page's web content process stopped"
            }
        }
    }
}

/// What the agent reads about permission requests.
public enum LeoBrowserPermissionText {
    /// The console code a denied request is logged under.
    public static let deniedCode = "permission_denied"

    /// The line that starts a snapshot while the tab waits on the user.
    /// `origin` is in the agent's (remote) terms.
    public static func waitingLine(kind: LeoBrowserPermissionKind, origin: String) -> String {
        "Waiting on the user: \(origin) asked for access to \(kind.agentNoun). Only the user can allow or deny it, in the browser pane; no tool answers it, and the page may wait until they do."
    }

    /// The console line for a denied request. `origin` is in the agent's (remote) terms.
    public static func deniedLine(kind: LeoBrowserPermissionKind, origin: String, because denial: LeoBrowserPermissionDenial) -> String {
        let reason: String
        switch denial {
        case .notShown:
            reason = "the browser pane wasn't showing this tab, so the user wasn't asked. Only the user can allow it, while this tab shows in the browser pane"
        case .user:
            reason = "the user chose Don't Allow"
        case .remembered:
            reason = "the user chose Don't Allow earlier in this tab, and the answer lasts until the tab closes"
        case .withdrawn(let withdrawal):
            reason = "the request was withdrawn before the user answered: \(withdrawal.reason)"
        }
        return "\(deniedCode): \(origin) was denied access to \(kind.agentNoun): \(reason)."
    }
}

/// Who is asking the user for something in an agent's browser, for the
/// file chooser and permission prompts alike.
public enum LeoBrowserRequestText {
    /// What a site with no host (`about:blank`) is called.
    static let noHost = "this page"

    /// `host` plus a non-default `port` (0 means the scheme's default), or
    /// "this page" when there is no host, as for `about:blank`.
    public static func originLabel(host: String, port: Int) -> String {
        guard !host.isEmpty else { return noHost }
        return port == 0 ? host : "\(host):\(port)"
    }

    /// "<agent> · <origin> wants to <wants>".
    public static func message(agent: String, origin: String, wants: String) -> String {
        "\(agent) · \(origin) wants to \(wants)"
    }
}
