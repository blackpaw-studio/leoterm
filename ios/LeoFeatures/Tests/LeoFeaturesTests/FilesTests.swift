import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct FilesTests {
    let notes = LeoSurfacedFile.make("f-md", path: "docs/notes.md", minute: 1, line: 12)
    let shot = LeoSurfacedFile.make("f-png", path: "out/shot.png", minute: 2)
    let tempURL = URL(fileURLWithPath: "/tmp/leo-previews/x/notes.md")

    func makeStore(files: [LeoSurfacedFile]? = nil) -> TestStoreOf<Files> {
        TestStore(initialState: Files.State(daemon: .dionysus, agentName: "zeus", files: files ?? [shot, notes], unseenIDs: ["f-md", "f-png"])) {
            Files()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
        }
    }

    @Test func aFileTheDaemonEvictedIsNoLongerAvailable() async {
        let store = makeStore()
        store.dependencies.surfacedFiles.download = { _, _, _, _ in throw LeoFileDownloadError.noLongerAvailable }

        await store.send(.fileTapped(notes.id)) { $0.opening = self.notes.id }
        await store.receive(\.downloaded) {
            $0.opening = nil
            $0.unavailableIDs = [self.notes.id]
            $0.alert = Files.unavailableAlert(self.notes)
        }
        await store.receive(\.delegate.opened)
    }

    @Test func otherDownloadFailuresExplainThemselvesAndLeaveTheFileUnread() async {
        let store = makeStore()
        store.dependencies.surfacedFiles.download = { _, _, _, _ in throw LeoDaemonError.transport("offline") }

        await store.send(.fileTapped(shot.id)) { $0.opening = self.shot.id }
        await store.receive(\.downloaded) {
            $0.opening = nil
            $0.alert = Files.failureAlert(self.shot, LeoDaemonError.transport("offline"))
        }
    }

    @Test func openingMarkdownReadsItsTextAtTheLine() async {
        let requests = LockIsolated<[(Int64, Bool)]>([])
        let store = makeStore()
        store.dependencies.surfacedFiles.download = { [tempURL] _, file, maxBytes, truncating in
            requests.withValue { $0.append((maxBytes, truncating)) }
            return LeoDownloadedFile(url: tempURL, totalBytes: 20, byteCount: 20)
        }
        store.dependencies.surfacedFiles.readText = { _ in "# Notes\n" }

        await store.send(.fileTapped(notes.id)) { $0.opening = self.notes.id }
        let preview = FilePreview.State(
            daemon: .dionysus, file: notes, localURL: tempURL, kind: .markdown, text: "# Notes\n", totalBytes: 20, isTruncated: false
        )
        await store.receive(\.downloaded) {
            $0.opening = nil
            $0.preview = preview
        }
        await store.receive(\.delegate.opened)
        #expect(store.state.preview?.line == 12)
        #expect(requests.value.map(\.0) == [FilePreviewKind.textPreviewCap])
        #expect(requests.value.map(\.1) == [true])
    }

    @Test func imagesGoToQuickLookWholeOrNotAtAll() async {
        let requests = LockIsolated<[(Int64, Bool)]>([])
        let pngURL = URL(fileURLWithPath: "/tmp/leo-previews/y/shot.png")
        let store = makeStore()
        store.dependencies.surfacedFiles.download = { _, _, maxBytes, truncating in
            requests.withValue { $0.append((maxBytes, truncating)) }
            return LeoDownloadedFile(url: pngURL, totalBytes: 2048, byteCount: 2048, contentType: "image/png")
        }

        await store.send(.fileTapped(shot.id)) { $0.opening = self.shot.id }
        await store.receive(\.downloaded) {
            $0.opening = nil
            $0.preview = FilePreview.State(daemon: .dionysus, file: self.shot, localURL: pngURL, kind: .quickLook, text: nil, totalBytes: 2048, isTruncated: false)
        }
        await store.receive(\.delegate.opened)
        #expect(requests.value.map(\.0) == [FilePreviewKind.quickLookCap])
        #expect(requests.value.map(\.1) == [false])
    }

    @Test func aFileWithoutAKnownTypeIsSniffed() async {
        let blob = LeoSurfacedFile.make("f-bin", path: "build/blob")
        let url = URL(fileURLWithPath: "/tmp/leo-previews/z/blob")
        let store = makeStore(files: [blob])
        store.dependencies.surfacedFiles.download = { _, _, _, _ in LeoDownloadedFile(url: url, totalBytes: 4, byteCount: 4) }
        store.dependencies.surfacedFiles.readText = { _ in nil }

        await store.send(.fileTapped(blob.id)) { $0.opening = blob.id }
        await store.receive(\.downloaded) {
            $0.opening = nil
            $0.preview = FilePreview.State(daemon: .dionysus, file: blob, localURL: url, kind: .quickLook, text: nil, totalBytes: 4, isTruncated: false)
        }
        await store.receive(\.delegate.opened)
    }

    @Test func aSecondTapWhileOpeningIsIgnored() async {
        let gate = AsyncStream<Void>.makeStream()
        let store = makeStore()
        store.dependencies.surfacedFiles.download = { [tempURL] _, _, _, _ in
            for await _ in gate.stream {}
            return LeoDownloadedFile(url: tempURL, totalBytes: 1, byteCount: 1)
        }
        store.dependencies.surfacedFiles.readText = { _ in "x" }
        await store.send(.fileTapped(notes.id)) { $0.opening = self.notes.id }
        await store.send(.fileTapped(shot.id))
        gate.continuation.finish()
        await store.receive(\.downloaded) {
            $0.opening = nil
            $0.preview = FilePreview.State(daemon: .dionysus, file: self.notes, localURL: self.tempURL, kind: .markdown, text: "x", totalBytes: 1, isTruncated: false)
        }
        await store.receive(\.delegate.opened)
    }
}

extension FilesTests {
    @Test func aDownloadThatOutlivesItsFileStillFreesTheList() async {
        let discarded = LockIsolated<[URL]>([])
        var initial = Files.State(daemon: .dionysus, agentName: "zeus", files: [shot], unseenIDs: [])
        initial.opening = "evicted"
        let gone = LeoSurfacedFile.make("evicted", path: "old.md")
        let store = TestStore(initialState: initial) { Files() } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
            $0.surfacedFiles.discard = { url in discarded.withValue { $0.append(url) } }
            $0.surfacedFiles.download = { _, _, _, _ in throw LeoDaemonError.transport("offline") }
        }
        let late = FilePreview.State(daemon: .dionysus, file: gone, localURL: tempURL, kind: .markdown, text: "x", totalBytes: 1, isTruncated: false)

        await store.send(.downloaded("evicted", .success(late))) { $0.opening = nil }
        await store.finish()
        #expect(discarded.value == [tempURL])

        await store.send(.fileTapped(shot.id)) { $0.opening = self.shot.id }
        await store.receive(\.downloaded) {
            $0.opening = nil
            $0.alert = Files.failureAlert(self.shot, LeoDaemonError.transport("offline"))
        }
    }
}

@MainActor
struct FilePreviewTests {
    let notes = LeoSurfacedFile.make("f-md", path: "docs/notes.md", minute: 1, line: 12)
    let excerpt = URL(fileURLWithPath: "/tmp/leo-previews/x/notes.md")
    let full = URL(fileURLWithPath: "/tmp/leo-previews/y/notes.md")

    func makeStore(isTruncated: Bool) -> TestStoreOf<FilePreview> {
        TestStore(initialState: FilePreview.State(
            daemon: .dionysus, file: notes, localURL: excerpt, kind: .markdown, text: "# Notes", totalBytes: 5 << 20, isTruncated: isTruncated
        )) {
            FilePreview()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "t") }
        }
    }

    @Test func sharingAWholePreviewSharesItsFile() async {
        let store = makeStore(isTruncated: false)
        await store.send(.shareButtonTapped) { $0.isSharing = true }
        #expect(store.state.shareURL == excerpt)
    }

    @Test func sharingATruncatedPreviewFetchesTheWholeFileFirst() async {
        let requests = LockIsolated<[(Int64, Bool)]>([])
        let store = makeStore(isTruncated: true)
        store.dependencies.surfacedFiles.download = { [full] _, _, maxBytes, truncating in
            requests.withValue { $0.append((maxBytes, truncating)) }
            return LeoDownloadedFile(url: full, totalBytes: 5 << 20, byteCount: 5 << 20)
        }

        await store.send(.shareButtonTapped) { $0.isPreparingShare = true }
        await store.receive(\.fullFileDownloaded) {
            $0.isPreparingShare = false
            $0.fullFileURL = self.full
            $0.isSharing = true
        }
        #expect(store.state.shareURL == full)
        #expect(store.state.temporaryFiles == [excerpt, full])
        #expect(requests.value.map(\.0) == [FilePreviewKind.quickLookCap])
        #expect(requests.value.map(\.1) == [false])

        await store.send(\.binding.isSharing, false) { $0.isSharing = false }
        await store.send(.shareButtonTapped) { $0.isSharing = true }
        #expect(requests.value.count == 1)
    }

    @Test func aFileTooLargeToShareSaysSo() async {
        let store = makeStore(isTruncated: true)
        store.dependencies.surfacedFiles.download = { _, _, _, _ in throw LeoFileDownloadError.tooLarge(200 << 20) }

        await store.send(.shareButtonTapped) { $0.isPreparingShare = true }
        await store.receive(\.fullFileDownloaded) {
            $0.isPreparingShare = false
            $0.alert = FilePreview.shareFailedAlert(LeoFileDownloadError.tooLarge(200 << 20))
        }
        #expect(store.state.shareURL == nil)
    }
}

struct FilePreviewKindTests {
    @Test(arguments: [
        ("notes.md", FilePreviewKind.markdown), ("README.markdown", .markdown),
        ("shot.png", .quickLook), ("photo.JPG", .quickLook), ("spec.pdf", .quickLook), ("demo.mov", .quickLook),
        ("plan.docx", .quickLook), ("budget.xlsx", .quickLook), ("deck.pptx", .quickLook), ("letter.rtf", .quickLook),
        ("main.swift", .text), ("config.yaml", .text), ("data.json", .text), ("log.txt", .text), ("page.html", .text),
        ("Makefile", .unknown), ("blob.zzqx", .unknown),
    ])
    func classifiesByFileName(name: String, kind: FilePreviewKind) {
        #expect(FilePreviewKind(fileName: name) == kind)
    }

    @Test func sniffsBinaryContent() {
        #expect(FilePreviewKind.decodeText(Data("plain\ntext".utf8)) == "plain\ntext")
        #expect(FilePreviewKind.decodeText(Data([0x89, 0x50, 0x00, 0x47])) == nil)
    }
}

struct MarkdownBlocksTests {
    let source = """
    # Title

    First paragraph
    continues here.

    - one
    - two

    ```swift
    let a = 1
    let b = 2
    ```
    Setext
    ---
    """

    @Test func splitsIntoBlocksWithTheirSourceLines() {
        let blocks = MarkdownBlocks(source).blocks
        #expect(blocks.map(\.lines) == [1...1, 3...4, 6...7, 9...12, 13...14])
        #expect(blocks.map(\.kind) == [.prose, .prose, .prose, .code(language: "swift"), .prose])
        #expect(blocks[3].text == "let a = 1\nlet b = 2")
        #expect(blocks[4].text == "Setext\n---")
    }

    @Test func findsTheBlockForALine() {
        let document = MarkdownBlocks(source)
        #expect(document.blockIndex(containing: 4) == 1)
        #expect(document.blockIndex(containing: 5) == 2)
        #expect(document.blockIndex(containing: 11) == 3)
        #expect(document.blockIndex(containing: 99) == nil)
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        let blocks = MarkdownBlocks("text\n~~~\ncode\n\nmore").blocks
        #expect(blocks.map(\.lines) == [1...1, 2...5])
        #expect(blocks[1].text == "code\n\nmore")
    }
}
