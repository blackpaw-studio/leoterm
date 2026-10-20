import AppKit
import OSLog

/// The real file system, Finder, workspace and alerts behind `LeoAppMover`.
/// Styling-only AppKit; the decisions it serves are tested through
/// `RecordingMoverEnvironment`.
@MainActor final class LeoLiveMoverEnvironment: LeoAppMoverEnvironment, LeoMoveHandoffEnvironment {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let instanceClaim: LeoSingleInstance.Claim
    private let bundleIdentifier: String?
    /// Runs the launch-and-trash once the quit is certain (AppDelegate calls it).
    private(set) lazy var handoff = LeoMoveHandoffCoordinator(environment: self)

    init(
        instanceClaim: LeoSingleInstance.Claim, fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared, bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.instanceClaim = instanceClaim
        self.fileManager = fileManager
        self.workspace = workspace
        self.bundleIdentifier = bundleIdentifier
    }

    func destinationState(at url: URL) -> LeoMoveDestinationState {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        let isRunning = bundleIdentifier.map { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        } ?? false
        return .present(isRunning: isRunning)
    }

    func isApplicationsWritable() -> Bool { fileManager.isWritableFile(atPath: LeoAppLocation.applicationsPath) }

    func copyBundle(from source: URL, to target: URL) async throws {
        let fileManager = fileManager
        try await LeoOffMain.run {
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: source, to: target)
        }
    }

    /// A leftover at `target` (a backup from an earlier crashed move) goes to
    /// the Trash first, never over.
    func moveBundle(from source: URL, to target: URL) async throws {
        let fileManager = fileManager
        try await LeoOffMain.run {
            if fileManager.fileExists(atPath: target.path) { try fileManager.trashItem(at: target, resultingItemURL: nil) }
            try fileManager.moveItem(at: source, to: target)
        }
    }

    func trash(_ url: URL) async throws {
        let fileManager = fileManager
        try await LeoOffMain.run { try fileManager.trashItem(at: url, resultingItemURL: nil) }
    }
    func markInstanceExiting() { instanceClaim.markExiting() }
    func clearInstanceExiting() { instanceClaim.clearExiting() }

    func terminate() { NSApp.terminate(nil) }
    func scheduleHandoff(_ handoff: LeoMoveHandoff) { self.handoff.arm(handoff) }

    /// `open -n` returns once LaunchServices has the request, so it can run
    /// while the app terminates; the copy then waits on the instance lock.
    func launchNewInstance(at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LeoHandoffLaunchError(status: process.terminationStatus) }
    }

    /// Synchronous on purpose: it runs while terminating, and trashing is a
    /// rename within the volume's own Trash.
    func trashOriginal(_ url: URL) throws { try fileManager.trashItem(at: url, resultingItemURL: nil) }

    func reportHandoffFailure(_ message: String) {
        Self.logger.error("handoff to the copy in Applications failed: \(message, privacy: .public)")
    }

    func askReplace(existing: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace the Leo in Applications?"
        alert.informativeText = "A copy of Leo is already in Applications. The existing copy goes to the Trash."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func explainRunningCopy(at url: URL) {
        let alert = NSAlert()
        alert.messageText = "Leo in Applications is already running"
        alert.informativeText = "Quit it, then move this copy again, or just open the copy in Applications."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        workspace.activateFileViewerSelecting([url])
    }

    func showManualInstructions(for bundleURL: URL) {
        let alert = NSAlert()
        alert.messageText = "Leo can’t write to Applications"
        alert.informativeText = "Drag Leo into the Applications folder yourself, then open it from there. Finder is showing Leo now."
        alert.addButton(withTitle: "OK")
        workspace.activateFileViewerSelecting([bundleURL])
        alert.runModal()
    }

    func report(error message: String) {
        Self.logger.error("move to Applications failed: \(message, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Leo couldn’t move itself to Applications"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// The launch prompt (HIG: a short question, the safe choice last, the
/// consequence of each choice in the button).
enum LeoMovePrompt {
    @MainActor static func confirm(reason: LeoMoveReason) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move Leo to the Applications folder?"
        alert.informativeText = informativeText(for: reason)
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func informativeText(for reason: LeoMoveReason) -> String {
        let why = "Leo’s background daemon starts at login and needs a permanent home."
        switch reason {
        case .translocated: return "macOS is running Leo from a temporary location. \(why)"
        case .readOnlyVolume: return "Leo is running from a disk image. \(why)"
        case .elsewhere: return why
        }
    }
}

struct LeoHandoffLaunchError: Error, LocalizedError {
    let status: Int32
    var errorDescription: String? { "open exited \(status)" }
}
