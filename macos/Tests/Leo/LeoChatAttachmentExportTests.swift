import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// B-346: a chat attachment dragged to Finder (a file promise) or saved
/// with "Download to…" writes the downloaded original, from the machine
/// it came from.
@MainActor @Suite(.timeLimit(.minutes(1)))
struct LeoChatAttachmentExportTests {
    private static let alpha = LeoAgentID(host: .local, name: "alpha")
    private static let box = LeoHostID.remote("box")
    private static let boxAlpha = LeoAgentID(host: box, name: "alpha")

    private let client = FakeChatClient()
    private let boxClient = FakeChatClient()
    private let root = FileManager.default.temporaryDirectory.appending(path: "leo-attachment-export-\(UUID().uuidString)")
    private var cache: URL { root.appending(path: "cache") }
    private var dropFolder: URL { root.appending(path: "drop") }

    private func makeChat() throws -> LeoChatPaneModel {
        try FileManager.default.createDirectory(at: dropFolder, withIntermediateDirectories: true)
        let model = LeoChatPaneModel(clients: [.local: client], recorder: FakeVoiceRecorder(), attachmentDirectory: cache)
        model.bind(boxClient, host: Self.box)
        return model
    }

    private func attachment(
        _ id: String = "f1", _ name: String = "a.txt", mime: String = "text/plain"
    ) -> LeoChatAttachment {
        LeoChatAttachment(id: id, filename: name, mime: mime, bytes: 4)
    }

    /// Calls the promise's delegate as AppKit does on a drop, returning
    /// what it completes with.
    private func write(_ promise: LeoFilePromise, to url: URL) async -> Error? {
        await withCheckedContinuation { continuation in
            promise.filePromiseProvider(promise, writePromiseTo: url) { continuation.resume(returning: $0) }
        }
    }

    private func contents(of folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
    }

    private func bytes(_ name: String, in folder: URL? = nil) throws -> Data {
        try Data(contentsOf: (folder ?? dropFolder).appending(path: name))
    }

    // MARK: Drag out

    @Test(arguments: [LeoHostID.local, LeoHostID.remote("box")])
    func aDroppedAttachmentWritesTheOriginalBytesUnderItsName(host: LeoHostID) async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = host == .local ? client : boxClient
        let other = host == .local ? boxClient : client
        await source.setDownload("f1", .success(Data("hello".utf8)))
        let chat = try makeChat()
        await chat.show(LeoAgentID(host: host, name: "alpha"))

        let promise = LeoChatAttachmentExport.promise(for: attachment(), host: nil, chat: chat)
        let error = await write(promise, to: dropFolder.appending(path: "a.txt"))

        #expect(error == nil)
        #expect(contents(of: dropFolder) == ["a.txt"])
        #expect(try bytes("a.txt") == Data("hello".utf8))
        #expect(await source.downloadCount == 1)
        #expect(await other.downloadCount == 0)
    }

    @Test func aPromiseKeepsTheMachineItWasDraggedFrom() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await boxClient.setDownload("f1", .success(Data("remote".utf8)))
        await client.setDownload("f1", .success(Data("local".utf8)))
        let chat = try makeChat()
        await chat.show(Self.boxAlpha)
        let promise = LeoChatAttachmentExport.promise(for: attachment(), host: nil, chat: chat)

        await chat.show(Self.alpha)
        let error = await write(promise, to: dropFolder.appending(path: "a.txt"))

        #expect(error == nil)
        #expect(try bytes("a.txt") == Data("remote".utf8))
        #expect(await boxClient.downloadCount == 1)
        #expect(await client.downloadCount == 0)
    }

    @Test func aDroppedImageIsTheOriginalNotTheThumbnail() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let tall = try #require(Self.tallPNG())
        await client.setDownload("img", .success(tall))
        let chat = try makeChat()
        await chat.show(Self.alpha)
        let image = attachment("img", "tall.png", mime: "image/png")
        await chat.loadAttachment(image)

        let error = await write(LeoChatAttachmentExport.promise(for: image, host: nil, chat: chat), to: dropFolder.appending(path: "tall.png"))

        #expect(error == nil)
        #expect(try bytes("tall.png") == tall)
        #expect(await client.downloadCount == 1)
    }

    @Test func aDropOntoATakenNameKeepsBoth() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await client.setDownload("f1", .success(Data("new".utf8)))
        let chat = try makeChat()
        await chat.show(Self.alpha)
        try Data("old".utf8).write(to: dropFolder.appending(path: "a.txt"))

        let error = await write(
            LeoChatAttachmentExport.promise(for: attachment(), host: nil, chat: chat), to: dropFolder.appending(path: "a.txt")
        )

        #expect(error == nil)
        #expect(try bytes("a.txt") == Data("old".utf8))
        #expect(try bytes("a 2.txt") == Data("new".utf8))
    }

    @Test func aFailedDropReturnsTheErrorLeavesNothingAndShowsANotice() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await client.setDownload("f1", .failure(.init(message: "gone")))
        let chat = try makeChat()
        await chat.show(Self.alpha)

        let error = await write(
            LeoChatAttachmentExport.promise(for: attachment(), host: nil, chat: chat), to: dropFolder.appending(path: "a.txt")
        )

        #expect(error?.localizedDescription == "gone")
        #expect(contents(of: dropFolder).isEmpty)
        #expect(chat.notice?.contains("a.txt") == true)
        #expect(chat.notice?.contains("gone") == true)
    }

    @Test func aDropAfterTheMachineDisconnectsFailsPlainly() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await boxClient.setDownload("f1", .success(Data("x".utf8)))
        let chat = try makeChat()
        await chat.show(Self.boxAlpha)
        let promise = LeoChatAttachmentExport.promise(for: attachment(), host: nil, chat: chat)

        chat.unbind(Self.box)
        let error = await write(promise, to: dropFolder.appending(path: "a.txt"))

        #expect(error?.localizedDescription == "\(Self.box.displayName) isn't connected.")
        #expect(contents(of: dropFolder).isEmpty)
        #expect(await boxClient.downloadCount == 0)
    }

    @Test func thePromiseNamesTheSanitizedOriginalFile() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = try makeChat()
        let promise = LeoChatAttachmentExport.promise(for: attachment("f1", "../../etc/passwd", mime: "text/plain"), host: nil, chat: chat)

        #expect(promise.filePromiseProvider(promise, fileNameForType: promise.fileType) == "passwd")
        let photo = LeoChatAttachmentExport.promise(for: attachment("f2", "shot.png", mime: "image/png"), host: nil, chat: chat)
        #expect(photo.fileType == "public.png")
        #expect(photo.operationQueue(for: photo) !== OperationQueue.main)
    }

    @Test func eachAttachmentInAMessageGetsItsOwnPromise() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await client.setDownload("f1", .success(Data("one".utf8)))
        await client.setDownload("f2", .success(Data("two".utf8)))
        let chat = try makeChat()
        await chat.show(Self.alpha)
        let first = LeoChatAttachmentExport.promise(for: attachment("f1", "one.txt"), host: nil, chat: chat)
        let second = LeoChatAttachmentExport.promise(for: attachment("f2", "two.txt"), host: nil, chat: chat)

        async let firstError = write(first, to: dropFolder.appending(path: "one.txt"))
        async let secondError = write(second, to: dropFolder.appending(path: "two.txt"))
        let errors = await [firstError, secondError]

        #expect(errors.allSatisfy { $0 == nil })
        #expect(try bytes("one.txt") == Data("one".utf8))
        #expect(try bytes("two.txt") == Data("two".utf8))
    }

    // MARK: Download to…

    @Test func downloadToCreatesANewFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await client.setDownload("f1", .success(Data("fresh".utf8)))
        let chat = try makeChat()
        await chat.show(Self.alpha)
        let destination = dropFolder.appending(path: "saved.txt")

        try await LeoChatAttachmentExport.save(attachment(), host: nil, chat: chat, to: destination)

        #expect(try bytes("saved.txt") == Data("fresh".utf8))
        #expect(contents(of: dropFolder) == ["saved.txt"])
    }

    @Test func downloadToReplacesTheChosenFile() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await client.setDownload("f1", .success(Data("fresh".utf8)))
        let chat = try makeChat()
        await chat.show(Self.alpha)
        try Data("old".utf8).write(to: dropFolder.appending(path: "saved.txt"))

        try await LeoChatAttachmentExport.save(attachment(), host: nil, chat: chat, to: dropFolder.appending(path: "saved.txt"))

        #expect(try bytes("saved.txt") == Data("fresh".utf8))
        #expect(contents(of: dropFolder) == ["saved.txt"])
    }

    @Test func aFailedDownloadToLeavesTheChosenFileAndShowsANotice() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        await client.setDownload("f1", .failure(.init(message: "gone")))
        let chat = try makeChat()
        await chat.show(Self.alpha)
        try Data("old".utf8).write(to: dropFolder.appending(path: "saved.txt"))

        await #expect(throws: LeoChatAttachmentExport.Unavailable.self) {
            try await LeoChatAttachmentExport.save(attachment(), host: nil, chat: chat, to: dropFolder.appending(path: "saved.txt"))
        }

        #expect(try bytes("saved.txt") == Data("old".utf8))
        #expect(chat.notice?.contains("a.txt") == true)
    }

    @Test func theSavePanelSuggestsTheOriginalFilename() {
        let panel = LeoChatAttachmentExport.makeSavePanel(for: attachment("f1", "../reports/Q3 summary.pdf", mime: "application/pdf"))

        #expect(panel.nameFieldStringValue == "Q3 summary.pdf")
        #expect(!panel.isExtensionHidden)
        #expect(panel.allowsOtherFileTypes)
        #expect(LeoChatAttachmentExport.downloadMenuTitle == "Download to…")
    }

    /// A 40 x 400 PNG: past the 2:1 crop the bubble applies.
    private static func tallPNG() -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
