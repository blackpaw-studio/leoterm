import Testing
import Foundation
import Sparkle
@testable import Ghostty

/// `UpdateDriver` hands Sparkle only gated replies: whatever the popover or
/// the standard alert answers, a debug build (installs not allowed) never
/// lets `.install` or a staged update's `.dismiss` reach Sparkle.
@MainActor
struct UpdateDriverGateTests {
    /// Records what reaches Sparkle's reply block.
    private final class Recorder<Value>: @unchecked Sendable {
        private(set) var values: [Value] = []
        func record(_ value: Value) { values.append(value) }
    }

    private func driver(unobtrusive: Bool, installsAllowed: Bool = false) -> UpdateDriver {
        UpdateDriver(
            viewModel: UpdateViewModel(),
            hostBundle: .main,
            installsAllowed: installsAllowed,
            hasUnobtrusiveTarget: { unobtrusive })
    }

    @Test func popoverInstallBeforeDownloadReachesSparkleAsDismiss() throws {
        let driver = driver(unobtrusive: true)
        let sparkle = Recorder<SPUUserUpdateChoice>()

        driver.showUpdateFound(with: .empty(), stage: .notDownloaded, reply: sparkle.record) { _ in
            Issue.record("the standard alert must not show while a terminal window can host the popover")
        }
        guard case let .updateAvailable(update) = driver.viewModel.state else {
            Issue.record("expected the update-available state, got \(driver.viewModel.state)")
            return
        }
        update.reply(.install)

        #expect(sparkle.values == [.dismiss])
    }

    @Test(arguments: [SPUUserUpdateStage.downloaded, .installing])
    func standardAlertAnswerOnAStagedUpdateReachesSparkleAsSkip(stage: SPUUserUpdateStage) {
        let driver = driver(unobtrusive: false)
        let sparkle = Recorder<SPUUserUpdateChoice>()
        var standardReply: (@Sendable (SPUUserUpdateChoice) -> Void)?

        driver.showUpdateFound(with: .empty(), stage: stage, reply: sparkle.record) { standardReply = $0 }
        standardReply?(.install)
        standardReply?(.dismiss)

        #expect(sparkle.values == [.skip, .skip])
    }

    @Test func readyToInstallReachesSparkleAsSkip() {
        let driver = driver(unobtrusive: true)
        let sparkle = Recorder<SPUUserUpdateChoice>()

        driver.showReady(toInstallAndRelaunch: sparkle.record)

        #expect(sparkle.values == [.skip])
    }

    @Test func releaseReadyToInstallStillInstalls() {
        let driver = driver(unobtrusive: true, installsAllowed: true)
        let sparkle = Recorder<SPUUserUpdateChoice>()

        driver.showReady(toInstallAndRelaunch: sparkle.record)

        #expect(sparkle.values == [.install])
    }

    @Test func permissionAnswerNeverTurnsOnDownloads() {
        let driver = driver(unobtrusive: true)
        let sparkle = Recorder<SUUpdatePermissionResponse>()

        driver.show(SPUUpdatePermissionRequest(systemProfile: []), reply: sparkle.record)
        guard case let .permissionRequest(request) = driver.viewModel.state else {
            Issue.record("expected the permission-request state, got \(driver.viewModel.state)")
            return
        }
        request.reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true, automaticUpdateDownloading: NSNumber(value: true), sendSystemProfile: false))

        #expect(sparkle.values.count == 1)
        #expect(sparkle.values.first?.automaticUpdateChecks == true)
        #expect(sparkle.values.first?.automaticUpdateDownloading?.boolValue == false)
    }
}
