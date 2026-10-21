import Foundation

/// Where the managed daemon stands after launch (B5), driving the sidebar.
enum LeoManagedStatus: Equatable, Sendable {
    /// Debug, a foreign marker, or a bundle without helpers: nothing to say.
    case inactive
    /// A CLI install runs (or could run) the daemon.
    case usingCLI(offerTakeover: Bool, isRunning: Bool)
    case settingUp
    case awaitingApproval
    case managed(version: String?)
    /// B6: restarting onto the bundled version after a Sparkle update.
    case updating(to: String)
    case moveRequired(isManaged: Bool)
    case failed(message: String)
}

/// A one-off message over the status, dismissed by the user.
struct LeoManagedNotice: Equatable, Sendable {
    let title: String
    let message: String
}

enum LeoManagedBannerAction: Equatable, Sendable {
    case takeOver, notNow, openLoginItems, moveToApplications, retry, dismiss

    var title: String {
        switch self {
        case .takeOver: "Let Leo Manage It"
        case .notNow: "Not Now"
        case .openLoginItems: "Open Login Items…"
        case .moveToApplications: "Move to Applications…"
        case .retry: "Try Again"
        case .dismiss: "OK"
        }
    }
}

struct LeoManagedBanner: Equatable, Sendable {
    let title: String
    let detail: String
    let actions: [LeoManagedBannerAction]
}

/// What the sidebar's "Start daemon" button becomes.
enum LeoDaemonStartAction: Equatable, Sendable {
    case setUp, allowInLoginItems, moveToApplications, startCLIDaemon

    var title: String {
        switch self {
        case .setUp: "Set Up Daemon"
        case .allowInLoginItems: "Allow in Login Items…"
        case .moveToApplications: "Move to Applications…"
        case .startCLIDaemon: "Start CLI Daemon"
        }
    }
}

struct LeoManagedPresentation: Equatable, Sendable {
    let banner: LeoManagedBanner?
    let startAction: LeoDaemonStartAction

    init(status: LeoManagedStatus, notice: LeoManagedNotice?) {
        banner = notice.map { LeoManagedBanner(title: $0.title, detail: $0.message, actions: [.dismiss]) } ?? Self.banner(for: status)
        startAction = Self.startAction(for: status)
    }

    private static func startAction(for status: LeoManagedStatus) -> LeoDaemonStartAction {
        switch status {
        case .inactive, .usingCLI: .startCLIDaemon
        case .settingUp, .managed, .updating, .failed: .setUp
        case .awaitingApproval: .allowInLoginItems
        case .moveRequired: .moveToApplications
        }
    }

    private static func banner(for status: LeoManagedStatus) -> LeoManagedBanner? {
        switch status {
        case .inactive, .managed, .usingCLI(offerTakeover: false, _), .moveRequired(isManaged: false):
            nil
        case .updating(let version):
            LeoManagedBanner(
                title: "Updating Leo’s daemon to \(version)…",
                detail: "Agents finish what they’re doing first, so this can take a few minutes.",
                actions: []
            )
        case .usingCLI(offerTakeover: true, _):
            LeoManagedBanner(
                title: "Let Leo run your daemon?",
                detail: "Leo can take over the leo daemon you installed, keep it running in the background and update it with the app. Your agents keep running.",
                actions: [.takeOver, .notNow]
            )
        case .settingUp:
            LeoManagedBanner(title: "Setting up Leo’s daemon…", detail: "This takes a few seconds.", actions: [])
        case .awaitingApproval:
            LeoManagedBanner(
                title: "Allow Leo in Login Items",
                detail: "Leo’s daemon runs in the background as a login item. Turn Leo on in System Settings ▸ General ▸ Login Items.",
                actions: [.openLoginItems]
            )
        case .moveRequired(isManaged: true):
            LeoManagedBanner(
                title: "Move Leo back to Applications",
                detail: "Leo runs your daemon from /Applications. The daemon keeps running, but Leo can’t update or restart it until the app is back there.",
                actions: [.moveToApplications]
            )
        case .failed(let message):
            LeoManagedBanner(title: "Leo’s daemon isn’t set up", detail: message, actions: [.retry])
        }
    }
}

/// For the menu bar extra.
struct LeoManagedSummary: Equatable, Sendable {
    let isManaged: Bool
    let version: String?
}
