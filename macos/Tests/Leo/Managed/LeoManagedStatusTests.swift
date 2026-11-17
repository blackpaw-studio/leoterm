import Testing

@testable import Ghostty

@MainActor
struct LeoManagedStatusTests {
    private static let everyStatus: [LeoManagedStatus] = [
        .inactive,
        .usingCLI(offerTakeover: true, isRunning: true),
        .usingCLI(offerTakeover: false, isRunning: false),
        .settingUp,
        .awaitingApproval,
        .managed(version: "0.52.0"),
        .updating(to: "0.53.0"),
        .runningOutsideJob(pid: 4242),
        .moveRequired(isManaged: true),
        .moveRequired(isManaged: false),
        .failed(message: "No helper"),
    ]

    @Test func everyStateHasAWordedSummary() {
        for status in Self.everyStatus {
            let summary = status.settingsSummary
            #expect(!summary.title.isEmpty, "\(status)")
            #expect(!summary.detail.isEmpty, "\(status)")
        }
        #expect(Set(Self.everyStatus.map { $0.settingsSummary.title }).count > 8)
    }

    @Test func theManagedSummaryReadsManagedByLeo() {
        let summary = LeoManagedStatus.managed(version: "0.52.0").settingsSummary
        #expect(summary.title == "Managed by Leo")
        #expect(summary.detail == "Leo.app starts this daemon at login and updates it with the app.")
    }

    @Test func aFailureSummaryCarriesTheMessage() {
        #expect(LeoManagedStatus.failed(message: "No helper").settingsSummary.detail == "No helper")
    }

    @Test func whileConnectedTheActionsAreTheBannerActions() {
        for status in Self.everyStatus {
            let presentation = LeoManagedPresentation(status: status, notice: nil)
            let expected = (presentation.banner?.actions ?? []).map(LeoManagedSettingsAction.banner)
            #expect(presentation.settingsActions(isConnected: true) == expected, "\(status)")
        }
    }

    @Test func whileNotConnectedTheStartActionIsOfferedOnceMore() {
        let presentation = LeoManagedPresentation(status: .inactive, notice: nil)
        #expect(presentation.settingsActions(isConnected: false) == [.start(.startCLIDaemon)])

        let offer = LeoManagedPresentation(status: .usingCLI(offerTakeover: true, isRunning: false), notice: nil)
        #expect(offer.settingsActions(isConnected: false) == [.banner(.takeOver), .banner(.notNow), .start(.startCLIDaemon)])
    }

    @Test func aStartActionABannerButtonAlreadyPerformsIsNotOfferedTwice() {
        let approval = LeoManagedPresentation(status: .awaitingApproval, notice: nil)
        #expect(approval.settingsActions(isConnected: false) == [.banner(.openLoginItems)])

        let failed = LeoManagedPresentation(status: .failed(message: "x"), notice: nil)
        #expect(failed.settingsActions(isConnected: false) == [.banner(.retry)])

        let move = LeoManagedPresentation(status: .moveRequired(isManaged: true), notice: nil)
        #expect(move.settingsActions(isConnected: false) == [.banner(.moveToApplications)])
    }

    @Test func aNoticeDoesNotHideTheStartAction() {
        let presentation = LeoManagedPresentation(status: .inactive, notice: LeoManagedNotice(title: "t", message: "m"))
        #expect(presentation.settingsActions(isConnected: false) == [.banner(.dismiss), .start(.startCLIDaemon)])
    }

    @Test func theFeedRunsTheActionItWasWiredFor() {
        let feed = LeoManagedDaemonFeed()
        var banner: [LeoManagedBannerAction] = []
        var start: [LeoDaemonStartAction] = []
        feed.performBanner = { banner.append($0) }
        feed.performStart = { start.append($0) }

        feed.perform(.banner(.takeOver))
        feed.perform(.start(.setUp))

        #expect(banner == [.takeOver])
        #expect(start == [.setUp])
    }

    @Test func theFeedPublishesWhatTheStartupReports() {
        let feed = LeoManagedDaemonFeed()
        let presentation = LeoManagedPresentation(status: .settingUp, notice: nil)
        feed.update(status: .settingUp, presentation: presentation)
        #expect(feed.status == .settingUp)
        #expect(feed.presentation == presentation)
    }
}
