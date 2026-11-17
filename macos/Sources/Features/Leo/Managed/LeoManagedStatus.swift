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
    /// B10: a daemon answers but the app's job isn't loaded.
    case runningOutsideJob(pid: Int32)
    case moveRequired(isManaged: Bool)
    case failed(message: String)
}

extension LeoManagedStatus {
    /// The state in words, for Settings ▸ This Mac ▸ Daemon.
    var settingsSummary: (title: String, detail: String) {
        switch self {
        case .inactive:
            ("Not managed by Leo", "This build doesn’t manage the daemon.")
        case .usingCLI(_, let isRunning):
            ("Using the leo command", isRunning ? "The leo daemon you installed runs on this Mac." : "The leo daemon you installed isn’t running.")
        case .settingUp:
            ("Setting up", "Leo is installing its daemon. This takes a few seconds.")
        case .awaitingApproval:
            ("Waiting for approval", "Turn Leo on in System Settings ▸ General ▸ Login Items.")
        case .managed:
            ("Managed by Leo", "Leo.app starts this daemon at login and updates it with the app.")
        case .updating(let version):
            ("Updating to \(version)", "Agents finish what they’re doing first, so this can take a few minutes.")
        case .runningOutsideJob:
            ("Running outside Leo.app", "Leo can’t restart or update this daemon until it runs from the app.")
        case .moveRequired:
            ("Leo is outside Applications", "Move Leo to Applications so it can run and update its daemon.")
        case .failed(let message):
            ("Daemon isn’t set up", message)
        }
    }
}

/// An action offered on the Settings daemon section: a banner action, or the
/// state's start action.
enum LeoManagedSettingsAction: Equatable, Sendable {
    case banner(LeoManagedBannerAction)
    case start(LeoDaemonStartAction)

    var title: String {
        switch self {
        case .banner(let action): action.title
        case .start(let action): action.title
        }
    }
}

extension LeoManagedPresentation {
    /// The state's banner actions, plus its start action while This Mac isn't
    /// connected (as on the sidebar's offline card). A start action that a
    /// banner button already performs isn't offered twice.
    func settingsActions(isConnected: Bool) -> [LeoManagedSettingsAction] {
        let bannerActions = banner?.actions ?? []
        let banners = bannerActions.map(LeoManagedSettingsAction.banner)
        let isDuplicate = startAction.equivalentBannerAction.map(bannerActions.contains) ?? false
        guard !isConnected, !isDuplicate else { return banners }
        return banners + [.start(startAction)]
    }
}

extension LeoDaemonStartAction {
    /// The banner action that does the same thing, if there is one.
    fileprivate var equivalentBannerAction: LeoManagedBannerAction? {
        switch self {
        case .setUp: .retry
        case .allowInLoginItems: .openLoginItems
        case .moveToApplications: .moveToApplications
        case .startCLIDaemon: nil
        }
    }
}

/// A one-off message over the status, dismissed by the user.
struct LeoManagedNotice: Equatable, Sendable {
    let title: String
    let message: String
}

enum LeoManagedBannerAction: Equatable, Sendable {
    case takeOver, notNow, openLoginItems, moveToApplications, retry, dismiss, stopOutsideDaemon

    var title: String {
        switch self {
        case .takeOver: "Let Leo Manage It"
        case .notNow: "Not Now"
        case .openLoginItems: "Open Login Items…"
        case .moveToApplications: "Move to Applications…"
        case .retry: "Try Again"
        case .dismiss: "OK"
        case .stopOutsideDaemon: "Stop It…"
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
        case .settingUp, .managed, .updating, .runningOutsideJob, .failed: .setUp
        case .awaitingApproval: .allowInLoginItems
        case .moveRequired: .moveToApplications
        }
    }

    private static func banner(for status: LeoManagedStatus) -> LeoManagedBanner? {
        switch status {
        case .inactive, .managed, .usingCLI(offerTakeover: false, _), .moveRequired(isManaged: false):
            nil
        case .runningOutsideJob(let pid):
            LeoManagedBanner(
                title: "A leo daemon (pid \(pid)) is running outside Leo.app",
                detail: "Leo can’t restart or update it. Stopping it shuts it down cleanly and your agents’ tmux sessions keep running; Leo then starts its own daemon.",
                actions: [.stopOutsideDaemon]
            )
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
    /// A leo daemon answers, but not from the app's job (B10).
    let isOutsideDaemon: Bool
    let version: String?
}
