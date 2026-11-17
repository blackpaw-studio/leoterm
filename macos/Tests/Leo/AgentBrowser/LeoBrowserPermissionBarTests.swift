import AppKit
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-410: the pane's permission bar names the agent, the site and what the
/// page wants; only a click answers it, and VoiceOver hears each prompt once.
@MainActor
struct LeoBrowserPermissionBarTests {
    private static let meet = LeoBrowserSite(scheme: "https", host: "meet.example.com", port: 8443)

    private func prompt(_ kind: LeoBrowserPermissionKind, id: Int = 1) -> LeoBrowserPermissionPrompt {
        LeoBrowserPermissionPrompt(id: id, agent: "alfred", request: LeoBrowserPermissionRequest(kind: kind, site: Self.meet))
    }

    @Test(arguments: [
        (LeoBrowserPermissionKind.camera, "alfred · meet.example.com:8443 wants to use your camera"),
        (.microphone, "alfred · meet.example.com:8443 wants to use your microphone"),
        (.cameraAndMicrophone, "alfred · meet.example.com:8443 wants to use your camera and microphone"),
        (.location, "alfred · meet.example.com:8443 wants to use your location"),
    ])
    func copyPerKind(kind: LeoBrowserPermissionKind, message: String) {
        let bar = LeoBrowserPermissionBar()
        bar.show(prompt(kind))
        #expect(!bar.isHidden)
        #expect(bar.messageLabel.stringValue == message)
        #expect(bar.detailLabel.stringValue == "Only you can answer. Your answer lasts until this tab closes.")
        #expect(bar.denyButton.title == "Don’t Allow")
        #expect(bar.allowButton.title == "Allow")
        #expect(bar.accessibilityLabel()?.hasPrefix(message) == true)
    }

    @Test func allowHasNoKeyEquivalent() {
        let bar = LeoBrowserPermissionBar()
        bar.show(prompt(.camera))
        #expect(bar.allowButton.keyEquivalent.isEmpty)
        #expect(bar.denyButton.keyEquivalent.isEmpty)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: .titled, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = bar
        #expect(window.defaultButtonCell == nil)
        let returnKey = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )
        var answers: [String] = []
        bar.onAllow = { answers.append("allow") }
        bar.onDeny = { answers.append("deny") }
        #expect(returnKey.map { bar.performKeyEquivalent(with: $0) } == false)
        #expect(answers.isEmpty)
        window.close()
    }

    @Test func clicksAnswer() {
        let bar = LeoBrowserPermissionBar()
        var answers: [String] = []
        bar.onAllow = { answers.append("allow") }
        bar.onDeny = { answers.append("deny") }
        bar.show(prompt(.location))
        bar.denyButton.performClick(nil)
        bar.allowButton.performClick(nil)
        #expect(answers == ["deny", "allow"])
    }

    /// Narrow panes put the buttons under the text; they keep the trailing
    /// inset rather than touching the pane's edge.
    @Test(arguments: [CGFloat(460), 800])
    func buttonsKeepTheTrailingInset(width: CGFloat) {
        let bar = LeoBrowserPermissionBar(frame: NSRect(x: 0, y: 0, width: width, height: 80))
        bar.show(prompt(.location))
        bar.layoutSubtreeIfNeeded()
        let allow = bar.convert(bar.allowButton.bounds, from: bar.allowButton)
        #expect(abs(allow.maxX - (width - 8)) <= 1, "Allow ends at \(allow.maxX) in a \(width)-wide bar")
    }

    @Test func hiddenWithoutRequest() {
        let bar = LeoBrowserPermissionBar()
        #expect(bar.isHidden)
        bar.show(prompt(.camera))
        bar.show(nil)
        #expect(bar.isHidden)
    }

    @Test func announcesOnceForVoiceOver() {
        let bar = LeoBrowserPermissionBar()
        var heard: [String] = []
        bar.onAnnounce = { heard.append($0) }
        bar.show(prompt(.camera, id: 1))
        bar.show(prompt(.camera, id: 1))
        bar.show(nil)
        bar.show(prompt(.camera, id: 1))
        bar.show(prompt(.location, id: 2))
        #expect(heard == [
            "alfred · meet.example.com:8443 wants to use your camera. Only you can answer. Your answer lasts until this tab closes.",
            "alfred · meet.example.com:8443 wants to use your location. Only you can answer. Your answer lasts until this tab closes.",
        ])
    }
}

/// B-410: the pane puts the bar under the handoff banner, shows the
/// source's waiting request, and its buttons answer it.
@MainActor
struct LeoBrowserPermissionPaneTests {
    @Test func thePaneShowsTheBarUnderTheBannerAndItsButtonsAnswer() async throws {
        let source = FakePaneSource()
        let pane = LeoAgentBrowserPaneViewController(source: source)
        let stack = try #require(pane.view as? NSStackView)
        let rows = stack.arrangedSubviews
        let banner = try #require(rows.firstIndex(of: pane.banner))
        #expect(rows.firstIndex(of: pane.permissionBar) == banner + 1)
        #expect(pane.permissionBar.isHidden)

        source.pendingPermission = LeoBrowserPermissionPrompt(
            id: 3, agent: "alfred",
            request: LeoBrowserPermissionRequest(kind: .camera, site: LeoBrowserSite(scheme: "https", host: "meet.example.com", port: 8443))
        )
        source.changed()
        await drainMainQueue()
        #expect(!pane.permissionBar.isHidden)
        #expect(pane.permissionBar.messageLabel.stringValue == "alfred · meet.example.com:8443 wants to use your camera")

        pane.permissionBar.allowButton.performClick(nil)
        #expect(source.calls == ["permission 3 allow"])
        #expect(source.control.state == .agent, "answering doesn't take control")
    }
}
