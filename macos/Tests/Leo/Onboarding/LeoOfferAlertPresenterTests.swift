import AppKit
import Testing

@testable import Ghostty

@MainActor struct LeoOfferAlertPresenterTests {
    private static func alert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Offer"
        alert.addButton(withTitle: "Set Up…")
        alert.addButton(withTitle: "Not Now")
        return alert
    }

    private static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private static func open(
        _ presenter: LeoOfferAlertPresenter, _ alert: NSAlert
    ) async -> Task<Bool, Never> {
        let task = Task { @MainActor in await presenter.present(alert) }
        for _ in 0..<1000 where !presenter.isOpen { await Task.yield() }
        return task
    }

    @Test func theMainActorStaysFreeWhileTheSheetIsOpen() async {
        let host = Self.window(), alert = Self.alert()
        let presenter = LeoOfferAlertPresenter(hostWindow: { host })
        let offer = await Self.open(presenter, alert)
        var processed = false

        await Task { @MainActor in processed = true }.value

        #expect(processed)
        #expect(host.attachedSheet != nil)
        presenter.withdraw()
        _ = await offer.value
    }

    @Test func setUpResolvesTrueAndNotNowFalse() async {
        let host = Self.window()
        let presenter = LeoOfferAlertPresenter(hostWindow: { host })
        let first = Self.alert()
        let setUp = await Self.open(presenter, first)
        first.buttons[0].performClick(nil)
        #expect(await setUp.value)
        #expect(!presenter.isOpen)

        let second = Self.alert()
        let notNow = await Self.open(presenter, second)
        second.buttons[1].performClick(nil)
        #expect(await notNow.value == false)
        #expect(host.attachedSheet == nil)
    }

    @Test func withdrawEndsTheSheetAndResolvesFalse() async {
        let host = Self.window()
        let presenter = LeoOfferAlertPresenter(hostWindow: { host })
        let offer = await Self.open(presenter, Self.alert())

        presenter.withdraw()

        #expect(await offer.value == false)
        #expect(host.attachedSheet == nil)
        #expect(!presenter.isOpen)
    }

    @Test func withdrawLeavesAnUnrelatedSheetAlone() async {
        let host = Self.window(), other = Self.window()
        let unrelated = Self.alert()
        unrelated.beginSheetModal(for: other, completionHandler: nil)
        let presenter = LeoOfferAlertPresenter(hostWindow: { host })
        let offer = await Self.open(presenter, Self.alert())

        presenter.withdraw()
        _ = await offer.value

        #expect(other.attachedSheet != nil)
        other.endSheet(unrelated.window)
    }

    @Test func withdrawWithNoOpenOfferDoesNothing() async {
        let host = Self.window(), unrelated = Self.alert()
        unrelated.beginSheetModal(for: host, completionHandler: nil)
        let presenter = LeoOfferAlertPresenter(hostWindow: { host })

        presenter.withdraw()

        #expect(host.attachedSheet != nil)
        host.endSheet(unrelated.window)
    }

    @Test func withoutAWindowThePanelIsNonBlockingAndAnswersTheButtons() async {
        let presenter = LeoOfferAlertPresenter(hostWindow: { nil })
        let alert = Self.alert()
        let offer = await Self.open(presenter, alert)
        var processed = false
        await Task { @MainActor in processed = true }.value
        #expect(processed)
        #expect(alert.window.isVisible)

        alert.buttons[0].performClick(nil)

        #expect(await offer.value)
        #expect(!alert.window.isVisible)
    }

    @Test func withoutAWindowWithdrawClosesThePanel() async {
        let presenter = LeoOfferAlertPresenter(hostWindow: { nil })
        let alert = Self.alert()
        let offer = await Self.open(presenter, alert)

        presenter.withdraw()

        #expect(await offer.value == false)
        #expect(!alert.window.isVisible)
    }

    @Test func aSecondOfferWhileOneIsOpenIsRefusedWithoutDisturbingTheFirst() async {
        let host = Self.window(), first = Self.alert()
        let presenter = LeoOfferAlertPresenter(hostWindow: { host })
        let offer = await Self.open(presenter, first)

        #expect(await presenter.present(Self.alert()) == false)
        #expect(presenter.isOpen)

        first.buttons[0].performClick(nil)
        #expect(await offer.value)
    }

    @Test func thePanelIsLaidOutBeforeItIsShown() async {
        let presenter = LeoOfferAlertPresenter(hostWindow: { nil })
        let alert = Self.alert()
        let offer = await Self.open(presenter, alert)
        let shown = alert.window.frame
        let shownButtons = alert.buttons.map(\.frame)

        // NSAlert only lays itself out when it runs: laying out again must move nothing.
        alert.layout()

        #expect(alert.window.frame == shown)
        #expect(alert.buttons.map(\.frame) == shownButtons)
        let bounds = alert.window.contentView?.bounds ?? .zero
        #expect(shown.width > 200 && shown.height > 100)
        for button in alert.buttons {
            let frame = button.convert(button.bounds, to: alert.window.contentView)
            #expect(frame.width > 20 && frame.height > 10)
            #expect(bounds.contains(frame))
        }

        presenter.withdraw()
        _ = await offer.value
    }
}
