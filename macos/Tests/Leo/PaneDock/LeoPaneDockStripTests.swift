import Testing

@testable import Ghostty
@testable import LeoKit

/// B-439: a row's one pane feeds a strip per edge. A strip shows the row's
/// front content when it hosts it, and its own best content otherwise.
@MainActor
struct LeoPaneDockStripTests {
    private static let agent = LeoRowKey.agent(LeoAgentIdentity(host: .local, name: "alpha"))
    private static let browserKey = LeoAgentBrowserKey(host: .local, agent: "alpha")

    private let presence: FakePresence
    /// Holds the row's pane: it watches the browser's presence while it lives.
    private let panes: LeoRowPanes

    init() {
        let presence = FakePresence()
        self.presence = presence
        panes = LeoRowPanes(makeAccess: { _ in LeoFileAccessor.local() }, confirm: { _, _ in .cancel }, presence: presence)
    }

    private func makePane() -> LeoRowPane {
        panes.pane(for: Self.agent)
    }

    @Test func aStripHostingBothShowsTheRowsFrontContent() {
        let pane = makePane()
        presence.open(Self.browserKey)

        #expect(pane.content(hosting: [.browser, .files]) == .agentBrowser)
        pane.showEditor()
        #expect(pane.content(hosting: [.browser, .files]) == .editor)
    }

    @Test func aBrowserOnlyStripShowsTheBrowserWhileItIsOpen() {
        let pane = makePane()
        #expect(pane.content(hosting: [.browser]) == nil)

        presence.open(Self.browserKey)
        pane.showEditor()

        #expect(pane.content(hosting: [.browser]) == .agentBrowser, "files in front elsewhere don't hide it")
        pane.closeAgentBrowser()
        #expect(pane.content(hosting: [.browser]) == nil)
    }

    @Test func aFilesStripShowsItsOwnContentWhileTheBrowserIsInFront() async throws {
        try await withLeoFileSandbox(.local) { sandbox, _ in
            let pane = makePane()
            presence.open(Self.browserKey)
            #expect(pane.content(hosting: [.files]) == .editor)

            let plugin = LeoPluginViewRef(
                pluginID: "p", pluginName: "Plugin", viewID: "v", title: "View", sfSymbol: "star",
                agent: LeoPluginAgentRef(machine: "localhost", name: "alpha"))
            pane.showPluginView(plugin)
            pane.showAgentBrowser()
            #expect(pane.content(hosting: [.files]) == .plugin(plugin), "the open view, with no files")

            try await pane.tabs.open(LeoEditorFileID(host: .local, path: try sandbox.file("a.txt", "a")))
            pane.showAgentBrowser()
            #expect(pane.content(hosting: [.files]) == .editor, "the files, once one is open")
            await pane.release()
        }
    }

    @Test func aStripHostingNothingShowsNothing() {
        let pane = makePane()
        presence.open(Self.browserKey)

        #expect(pane.content(hosting: []) == nil)
    }
}
