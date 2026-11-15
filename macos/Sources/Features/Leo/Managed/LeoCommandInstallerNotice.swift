import Foundation

/// The wording for Leo ▸ "Install ‘leo’ Command…", apart from the alerts
/// that show it so it can be tested.
struct LeoCommandInstallerNotice: Equatable {
    enum Style: Equatable {
        case informational
        case warning
    }

    let style: Style
    let title: String
    let message: String

    private static let commandPath = "~/.local/bin/leo"
    private static let refusalTitle = "Leo can’t install the ‘leo’ command"

    /// nil when there is nothing to say (the user declined the replacement).
    static func notice(for outcome: LeoCommandInstaller.Outcome) -> Self? {
        switch outcome {
        case .declined:
            nil
        case let .installed(pathHint):
            Self(
                style: .informational, title: "‘leo’ command installed",
                message: (["\(commandPath) now runs the copy of leo inside Leo."] + [pathHint].compactMap { $0 })
                    .joined(separator: "\n\n")
            )
        case .alreadyInstalled:
            Self(
                style: .informational, title: "‘leo’ command is already installed",
                message: "\(commandPath) already runs the copy of leo inside Leo."
            )
        case let .refused(refusal):
            Self(style: .warning, title: refusalTitle, message: message(for: refusal))
        }
    }

    static func confirmReplace(backup: URL) -> Self {
        Self(
            style: .warning, title: "Replace the existing ‘leo’ command?",
            message: "\(commandPath) already exists. Leo moves it to \(backup.path) (it is not deleted) "
                + "and links the copy of leo inside Leo in its place. Releasing Leo’s daemon back to the CLI restores it."
        )
    }

    static func failure(_ error: any Error) -> Self {
        Self(style: .warning, title: refusalTitle, message: "\(error)")
    }

    private static func message(for refusal: LeoCommandInstaller.Refusal) -> String {
        switch refusal {
        case .directory:
            "\(commandPath) is a folder, so Leo left it alone. Move or remove it, then try again."
        case .backupExists:
            "An earlier ‘leo’ was already saved as \(LeoInstallPaths.backupFileName) next to it. "
                + "Move or remove that backup, then try again, so Leo never overwrites it."
        case .helperLinkMissing:
            "Leo hasn’t linked its own copy of leo at ~/.leo/app/bin/leo yet, so the command would point nowhere. "
                + "That happens when Leo manages its daemon from the Applications folder."
        }
    }
}
