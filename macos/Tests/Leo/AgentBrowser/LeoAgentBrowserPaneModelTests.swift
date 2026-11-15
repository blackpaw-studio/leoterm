import Combine
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// E2: what the browser pane's toolbar says and does, apart from drawing it.
@MainActor
struct LeoAgentBrowserPaneModelTests {
    private let source = FakePaneSource()

    private func model() -> LeoAgentBrowserPaneModel { LeoAgentBrowserPaneModel(source: source) }

    @Test
    func pillSaysWhoIsDriving() {
        let model = model()
        #expect(model.pill.title == "Agent driving")
        #expect(!model.pill.canGiveBack)

        source.control.send(.userInput)
        #expect(model.pill.title == "You have control")
        #expect(model.pill.canGiveBack)

        source.control.send(.giveBack)
        source.control.send(.handoff(requestID: "r", message: "Log in"))
        #expect(model.pill.title == "You have control")
        #expect(!model.pill.canGiveBack, "a handoff is answered with Done or Decline")
    }

    @Test
    func clickingThePillTakesControlAndGiveBackReturnsIt() {
        let model = model()

        model.pillClicked()
        #expect(source.control.state == .user)

        model.giveBack()
        #expect(source.control.state == .agent)
    }

    @Test
    func urlBarShowsTheActiveTabsRemoteURL() {
        let model = model()
        #expect(model.urlText == "")

        source.activeRemoteURL = URL(string: "http://localhost:5173/app?x=1")
        source.changed()

        #expect(model.urlText == "http://localhost:5173/app?x=1")
    }

    @Test
    func enterInTheURLBarIsUserInputAndNavigates() {
        let model = model()

        model.submitURL("localhost:5173/app")

        #expect(source.control.state == .user)
        #expect(source.calls == ["navigate http://localhost:5173/app"])
        #expect(model.urlError == nil)
    }

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  https://example.com/a?b=1#c ", "https://example.com/a?b=1#c"),
        ("http://example.com", "http://example.com"),
        ("localhost:3000", "http://localhost:3000"),
        ("127.0.0.1:8080/x", "http://127.0.0.1:8080/x"),
        ("[::1]:5173", "http://[::1]:5173"),
        ("about:blank", "about:blank"),
    ])
    func urlBarTextBecomesAURL(text: String, expected: String) {
        #expect(LeoAgentBrowserPaneModel.url(fromInput: text)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com", "data:text/html,hi"])
    func urlBarRefusesWhatTheBrowserWouldNotLoad(text: String) {
        let model = model()

        model.submitURL(text)

        #expect(source.calls.isEmpty)
        #expect(model.urlError != nil)
    }

    @Test
    func tabItemsMirrorTheTabs() {
        let model = model()
        source.fakeTabs.tabs = [
            LeoBrowserTabInfo(id: 4, url: URL(string: "http://localhost:5173"), title: "Vite App", isActive: false),
            LeoBrowserTabInfo(id: 7, url: nil, title: "", isActive: true),
        ]
        source.changed()

        #expect(model.tabItems == [
            LeoAgentBrowserPaneModel.TabItem(id: 4, title: "Vite App", isActive: false),
            LeoAgentBrowserPaneModel.TabItem(id: 7, title: "New Tab", isActive: true),
        ])
    }

    @Test
    func toolbarActionsAreUserInput() {
        let model = model()
        source.canGoBack = true
        source.changed()
        #expect(model.canGoBack)

        model.goBack()
        #expect(source.control.state == .user)
        source.control.send(.giveBack)
        model.goForward()
        source.control.send(.giveBack)
        model.reload()
        source.control.send(.giveBack)
        model.newTab()

        #expect(source.calls == ["back", "forward", "reload", "newTab"])
        #expect(source.control.state == .user)
    }

    @Test
    func tabClicksSelectAndCloseThroughTheTabsAsUserInput() {
        let model = model()

        model.selectTab(id: 4)
        #expect(source.control.state == .user)
        model.closeTab(id: 7)

        #expect(source.fakeTabs.selected == [4])
        #expect(source.fakeTabs.closed == [7])
    }

    @Test
    func announcesSourceAndControlChanges() {
        let model = model()
        var announced = 0
        let subscription = model.objectWillChange.sink { announced += 1 }

        source.isLoading = true
        source.changed()
        source.control.send(.userInput)

        #expect(announced == 2)
        #expect(model.isLoading)
        subscription.cancel()
    }
}
