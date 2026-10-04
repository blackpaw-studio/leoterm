import Cocoa
import Sparkle

/// Implement the SPUUserDriver to modify our UpdateViewModel for custom presentation.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    let standard: SPUStandardUserDriver
    /// False in debug builds: every reply to Sparkle is gated so nothing
    /// is ever installed (see `UpdatePolicy`).
    let installsAllowed: Bool
    private let unobtrusiveTargetCheck: () -> Bool
    private let unobtrusiveTargetOpener: () -> Void

    init(
        viewModel: UpdateViewModel,
        hostBundle: Bundle,
        installsAllowed: Bool = UpdatePolicy.installsAllowed,
        hasUnobtrusiveTarget: @escaping () -> Bool = UpdateDriver.anyTerminalWindowIsVisible,
        openUnobtrusiveTarget: @escaping () -> Void = UpdateDriver.openTerminalWindow
    ) {
        self.viewModel = viewModel
        self.standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        self.installsAllowed = installsAllowed
        self.unobtrusiveTargetCheck = hasUnobtrusiveTarget
        self.unobtrusiveTargetOpener = openUnobtrusiveTarget
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminalWindowWillClose),
            name: TerminalWindow.terminalWillCloseNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleTerminalWindowWillClose() {
        // If we lost the ability to show unobtrusive states, cancel whatever
        // update state we're in. This will allow the manual `check for updates`
        // call to initialize the standard driver. A pending permission
        // request is the exception: it stays, and `showUpdateInFocus` opens
        // a window for its pill instead.
        //
        // We have to do this after a short delay so that the window can fully
        // close.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            guard !hasUnobtrusiveTarget else { return }
            // A pending permission request has no cancel, and clearing it
            // would drop Sparkle's question unanswered: keep it for the next
            // window's pill (B-128).
            if case .permissionRequest = viewModel.state { return }
            viewModel.state.cancel()
            viewModel.state = .idle
        }
    }

    /// Sparkle's "check for updates automatically?" request. The pill's
    /// popover is the only prompt, with no standard-alert fallback: Sparkle
    /// asks right after launch, before the first terminal window is on
    /// screen, so a fallback alert plus that window's pill asked twice
    /// (B-128). Sparkle waits for the reply, so the request simply waits for
    /// the first window.
    func show(_ request: SPUUpdatePermissionRequest,
              reply sparkleReply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        // Debug builds never let an answer turn on automatic downloads.
        let installsAllowed = installsAllowed
        let reply: @Sendable (SUUpdatePermissionResponse) -> Void = { response in
            sparkleReply(UpdatePolicy.gatedPermission(response, installsAllowed: installsAllowed))
        }
        viewModel.state = .permissionRequest(.init(request: request, reply: { [weak viewModel] response in
            viewModel?.state = .idle
            reply(response)
        }))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        viewModel.state = .checking(.init(cancel: cancellation))

        if !hasUnobtrusiveTarget {
            standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        showUpdateFound(with: appcastItem, stage: state.stage, reply: reply) { [standard] gatedReply in
            standard.showUpdateFound(with: appcastItem, state: state, reply: gatedReply)
        }
    }

    /// `showUpdateFound` given only the update's stage, so tests can drive
    /// it (`SPUUserUpdateState` has no public initializer). Debug builds can
    /// find an update but never install it: both the popover and the
    /// standard alert (`showStandardAlert`) get the gated reply.
    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        stage: SPUUserUpdateStage,
        reply sparkleReply: @escaping @Sendable (SPUUserUpdateChoice) -> Void,
        showStandardAlert: (@escaping @Sendable (SPUUserUpdateChoice) -> Void) -> Void
    ) {
        let reply = gated(sparkleReply, stage: stage)
        viewModel.state = .updateAvailable(.init(appcastItem: appcastItem, reply: reply))
        if !hasUnobtrusiveTarget {
            showStandardAlert(reply)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // We don't do anything with the release notes here because Ghostty
        // doesn't use the release notes feature of Sparkle currently.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // We don't do anything with release notes. See `showUpdateReleaseNotes`
    }

    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        viewModel.state = .notFound(.init(acknowledgement: acknowledgement))

        if !hasUnobtrusiveTarget {
            standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        }
    }

    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        viewModel.state = .error(.init(
            error: error,
            retry: { [weak self, weak viewModel] in
                viewModel?.state = .idle
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(self)
                }
            },
            dismiss: {
                acknowledgement()
            }))

        if !hasUnobtrusiveTarget {
            standard.showUpdaterError(error, acknowledgement: acknowledgement)
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        viewModel.state = .downloading(.init(
            cancel: cancellation,
            expectedLength: nil,
            progress: 0))

        if !hasUnobtrusiveTarget {
            standard.showDownloadInitiated(cancellation: cancellation)
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        viewModel.state = .downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0))

        if !hasUnobtrusiveTarget {
            standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }

        viewModel.state = .downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length))

        if !hasUnobtrusiveTarget {
            standard.showDownloadDidReceiveData(ofLength: length)
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        viewModel.state = .extracting(.init(progress: 0))

        if !hasUnobtrusiveTarget {
            standard.showDownloadDidStartExtractingUpdate()
        }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        viewModel.state = .extracting(.init(progress: progress))

        if !hasUnobtrusiveTarget {
            standard.showExtractionReceivedProgress(progress)
        }
    }

    func showReady(toInstallAndRelaunch sparkleReply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        // The update is already downloaded: a debug build skips it, since
        // Dismiss would still install it when the app quits.
        let reply = gated(sparkleReply, stage: .downloaded)
        if !hasUnobtrusiveTarget {
            standard.showReady(toInstallAndRelaunch: reply)
        } else {
            reply(.install)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        viewModel.state = .installing(.init(
            appcastItem: nil,
            retryTerminatingApplication: retryTerminatingApplication,
        ))

        if !hasUnobtrusiveTarget {
            standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
        viewModel.state = .idle
    }

    /// Sparkle calls this for Check for Updates… while it is still waiting
    /// for an answer, instead of checking. A pending permission request
    /// lives only in the pill (B-128), so with no window to show the pill,
    /// open one; the standard driver has no prompt of its own to bring
    /// forward.
    func showUpdateInFocus() {
        guard !hasUnobtrusiveTarget else { return }
        if case .permissionRequest = viewModel.state {
            unobtrusiveTargetOpener()
            return
        }
        standard.showUpdateInFocus()
    }

    func dismissUpdateInstallation() {
        viewModel.state = .idle
        standard.dismissUpdateInstallation()
    }

    // MARK: No-Window Fallback

    /// True if there is a target that can render our unobtrusive update checker.
    var hasUnobtrusiveTarget: Bool {
        unobtrusiveTargetCheck()
    }

    static func anyTerminalWindowIsVisible() -> Bool {
        NSApp.windows.contains { window in
            (window is TerminalWindow || window is QuickTerminalWindow) &&
            window.isVisible
        }
    }

    /// Opens a terminal window (File > New Window), whose pill can then
    /// show the current state.
    static func openTerminalWindow() {
        (NSApp.delegate as? AppDelegate)?.newWindow(nil)
    }

    // MARK: Install Gate

    /// `sparkleReply`, answering through `UpdatePolicy.gatedChoice`.
    private func gated(
        _ sparkleReply: @escaping @Sendable (SPUUserUpdateChoice) -> Void,
        stage: SPUUserUpdateStage
    ) -> @Sendable (SPUUserUpdateChoice) -> Void {
        let installsAllowed = installsAllowed
        return { choice in
            sparkleReply(UpdatePolicy.gatedChoice(choice, stage: stage, installsAllowed: installsAllowed))
        }
    }
}
