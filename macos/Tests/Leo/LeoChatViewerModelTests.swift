import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// What the chat pane's viewer shows, and when it goes away: it follows
/// one agent's thread in one window and never outlives it.
@MainActor
struct LeoChatViewerModelTests {
    private static let a = LeoAgentID(host: .local, name: "a")
    private static let b = LeoAgentID(host: .local, name: "b")

    /// Downloads that only finish when the test says so.
    @MainActor final class Downloads {
        private var held: [CheckedContinuation<URL?, Never>] = []
        var heldCount: Int { held.count }

        func wait() async -> URL? { await withCheckedContinuation { held.append($0) } }

        func finish(_ index: Int, with url: URL?) { held[index].resume(returning: url) }

        func waitUntilHeld(_ count: Int) async {
            while held.count < count { await Task.yield() }
        }
    }

    private final class Opened {
        var urls: [URL] = []
    }

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-model-\(UUID().uuidString)", isDirectory: true)
    private let opened = Opened()

    private func makeModel() -> LeoChatViewerModel {
        let opened = opened
        return LeoChatViewerModel(openExternally: { opened.urls.append($0) })
    }

    private func file(_ name: String, _ bytes: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func attachment(_ id: String, _ filename: String) -> LeoChatAttachment {
        LeoChatAttachment(id: id, filename: filename, mime: "application/octet-stream", bytes: 1)
    }

    private func openMarkdown(_ model: LeoChatViewerModel, for agent: LeoAgentID = a, id: String = "m1") async throws {
        let url = try file("\(id).md", Data("# \(id)".utf8))
        await model.open(attachment(id, "\(id).md"), for: agent, download: { url })
    }

    @Test func aMarkdownAttachmentOpensTheViewer() async throws {
        let model = makeModel()
        try await openMarkdown(model)
        #expect(model.document(for: Self.a)?.filename == "m1.md")
        #expect(model.document(for: Self.a)?.content == .markdown)
        #expect(opened.urls.isEmpty)
    }

    @Test func aBinaryAttachmentOpensInTheDefaultAppInstead() async throws {
        let model = makeModel()
        let url = try file("blob.bin", Data([0, 1, 2]))
        await model.open(attachment("b1", "blob.bin"), for: Self.a, download: { url })
        #expect(model.shown == nil)
        #expect(opened.urls == [url])
    }

    @Test func aFailedDownloadDoesNothing() async {
        let model = makeModel()
        await model.open(attachment("m1", "m1.md"), for: Self.a, download: { nil })
        #expect(model.shown == nil)
        #expect(opened.urls.isEmpty)
    }

    @Test func closeClearsTheViewer() async throws {
        let model = makeModel()
        try await openMarkdown(model)
        model.close()
        #expect(model.shown == nil)
    }

    @Test func anotherAgentsSelectionClosesItAndComingBackShowsTheThread() async throws {
        let model = makeModel()
        try await openMarkdown(model)
        model.agentChanged(to: Self.b)
        #expect(model.shown == nil)
        model.agentChanged(to: Self.a)
        #expect(model.document(for: Self.a) == nil)
    }

    @Test func reselectingTheShownAgentKeepsTheViewer() async throws {
        let model = makeModel()
        try await openMarkdown(model)
        model.agentChanged(to: Self.a)
        #expect(model.document(for: Self.a) != nil)
    }

    @Test func theViewerBelongsToItsAgentOnly() async throws {
        let model = makeModel()
        try await openMarkdown(model, for: Self.a)
        #expect(model.document(for: Self.b) == nil)
        #expect(model.document(for: nil) == nil)
    }

    @Test(arguments: [false, true])
    func closingOrSwitchingDuringADownloadOpensNothing(switchesAgent: Bool) async throws {
        let model = makeModel()
        let downloads = Downloads()
        let url = try file("m1.md", Data("# hi".utf8))
        let open = Task { await model.open(attachment("m1", "m1.md"), for: Self.a, download: { await downloads.wait() }) }
        await downloads.waitUntilHeld(1)
        if switchesAgent { model.agentChanged(to: Self.b) } else { model.close() }
        downloads.finish(0, with: url)
        await open.value
        #expect(model.shown == nil)
        #expect(opened.urls.isEmpty)
    }

    @Test func theLaterClickWinsWhenDownloadsFinishOutOfOrder() async throws {
        let model = makeModel()
        let downloads = Downloads()
        let first = try file("first.md", Data("# first".utf8))
        let second = try file("second.md", Data("# second".utf8))
        let one = Task { await model.open(attachment("1", "first.md"), for: Self.a, download: { await downloads.wait() }) }
        await downloads.waitUntilHeld(1)
        let two = Task { await model.open(attachment("2", "second.md"), for: Self.a, download: { await downloads.wait() }) }
        await downloads.waitUntilHeld(2)
        downloads.finish(1, with: second)
        await two.value
        downloads.finish(0, with: first)
        await one.value
        #expect(model.shown?.document.attachmentID == "2")
    }

    // MARK: Through the window session

    private func makeSession(contentWidth: CGFloat = 800) -> LeoWindowSession {
        let session = LeoWindowSession(defaults: LeoInMemoryDefaults())
        session.selectedAgent = { Self.a }
        session.setObservedContentWidth(contentWidth)
        return session
    }

    @Test func switchingToTerminalClosesTheViewer() async throws {
        let session = makeSession()
        session.choose(.chat, for: Self.a)
        try await openMarkdown(session.chatViewer)
        session.choose(.terminal, for: Self.a)
        #expect(session.chatViewer.shown == nil)
    }

    @Test func clickingTheChatSegmentWhileChatShowsClosesTheViewer() async throws {
        let session = makeSession()
        session.choose(.chat, for: Self.a)
        try await openMarkdown(session.chatViewer)
        session.select(.chat, for: Self.a)
        #expect(session.chatViewer.shown == nil)
    }

    @Test func choosingChatKeepsTheViewer() async throws {
        let session = makeSession()
        session.choose(.chat, for: Self.a)
        try await openMarkdown(session.chatViewer)
        session.choose(.chat, for: Self.a)
        #expect(session.chatViewer.document(for: Self.a) != nil)
    }
}
