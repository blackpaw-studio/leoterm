import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import Testing
import UIKit

@testable import Leo

/// The full-screen image viewer: pages through one message's images, shows each
/// whole, and stays out of the way of the chat underneath.
@MainActor
struct ChatImageViewerTests {
    typealias File = ChatThread.AttachmentFile

    private static func png(_ name: String, size: CGSize) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "viewer-\(UUID().uuidString)-\(name).png")
        try UIGraphicsImageRenderer(size: size, format: .init(for: .init(displayScale: 1))).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.write(to: url)
        return url
    }

    private static func gallery(_ ids: [String], start: Int) -> LeoChatImageGallery {
        let attachments = ids.map { LeoChatAttachment(id: $0, filename: "\($0).png", mime: "image/png", bytes: 10) }
        let message = LeoChatMessage(
            id: "m", agent: "a", direction: .inbound, kind: .text, text: "", ts: Date(timeIntervalSince1970: 0), attachments: attachments
        )
        return LeoChatImageGallery(message: message, tappedID: ids[start])!
    }

    private static func window(for root: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        return window
    }

    private static func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private static func viewer(
        _ ids: [String], start: Int, files: [String: File], need: @escaping (LeoChatAttachment) -> Void = { _ in }
    ) -> ChatImageViewerController {
        let viewer = ChatImageViewerController(gallery: gallery(ids, start: start), file: { files[$0] ?? .loading }, need: need)
        viewer.loadViewIfNeeded()
        return viewer
    }

    private static func loaded(_ ids: [String]) throws -> [String: File] {
        try Dictionary(uniqueKeysWithValues: ids.map { ($0, File.loaded(try png($0, size: CGSize(width: 100, height: 100)))) })
    }

    @Test func opensAtTheTappedImageWithItsPosition() throws {
        let ids = ["a", "b", "c", "d"]
        let viewer = Self.viewer(ids, start: 1, files: try Self.loaded(ids))

        #expect(viewer.positionLabel.text == "2 of 4")
        #expect(viewer.positionLabel.isHidden == false)
        #expect(viewer.currentPage?.attachment.id == "b")
        #expect(viewer.currentPage?.imageView.image != nil)
    }

    @Test func pagesInOrderAndStopsAtTheEnds() throws {
        let ids = ["a", "b", "c"]
        let viewer = Self.viewer(ids, start: 1, files: try Self.loaded(ids))
        let middle = try #require(viewer.currentPage)

        let after = viewer.pageViewController(viewer.pageController, viewControllerAfter: middle) as? ChatImagePageController
        let before = viewer.pageViewController(viewer.pageController, viewControllerBefore: middle) as? ChatImagePageController
        #expect(after?.attachment.id == "c")
        #expect(before?.attachment.id == "a")
        #expect(viewer.pageViewController(viewer.pageController, viewControllerAfter: try #require(after)) == nil)
        #expect(viewer.pageViewController(viewer.pageController, viewControllerBefore: try #require(before)) == nil)

        viewer.didShow( try #require(after))
        #expect(viewer.positionLabel.text == "3 of 3")
    }

    @Test func aSingleImageHasNoPagingAndNoPosition() throws {
        let viewer = Self.viewer(["a"], start: 0, files: try Self.loaded(["a"]))
        let only = try #require(viewer.currentPage)

        #expect(viewer.positionLabel.isHidden)
        #expect(viewer.pageViewController(viewer.pageController, viewControllerAfter: only) == nil)
        #expect(viewer.pageViewController(viewer.pageController, viewControllerBefore: only) == nil)
    }

    @Test func showsTheFullUncroppedOriginal() throws {
        let tall = try Self.png("tall", size: CGSize(width: 100, height: 400))
        let viewer = Self.viewer(["a"], start: 0, files: ["a": .loaded(tall)])
        let image = try #require(viewer.currentPage?.imageView.image)

        #expect(image.size.width / image.size.height == 0.25)
        #expect(viewer.currentPage?.imageView.contentMode == .scaleAspectFit)
    }

    @Test func anUnloadedImageLoadsInPlace() throws {
        let needed = LockIsolated<[String]>([])
        let files = LockIsolated<[String: File]>(["a": .loading])
        let viewer = ChatImageViewerController(
            gallery: Self.gallery(["a"], start: 0), file: { files.value[$0] ?? .loading }, need: { attachment in needed.withValue { $0.append(attachment.id) } }
        )
        viewer.loadViewIfNeeded()
        let page = try #require(viewer.currentPage)
        #expect(page.spinner.isAnimating)
        #expect(page.imageView.image == nil)
        #expect(needed.value == ["a"])

        let url = try Self.png("a", size: CGSize(width: 50, height: 50))
        files.withValue { $0["a"] = .loaded(url) }
        viewer.refresh()

        #expect(page.imageView.image != nil)
        #expect(page.spinner.isAnimating == false)
    }

    @Test func aFailedImageOffersRetry() throws {
        let needed = LockIsolated<[String]>([])
        let viewer = Self.viewer(["a"], start: 0, files: ["a": .failed("Offline")], need: { attachment in needed.withValue { $0.append(attachment.id) } })
        let page = try #require(viewer.currentPage)
        needed.withValue { $0 = [] }

        #expect(page.failureLabel.text?.contains("Offline") == true)
        #expect(page.retryButton.isHidden == false)
        page.retryButton.sendActions(for: .primaryActionTriggered)
        #expect(needed.value == ["a"])
    }

    @Test func closeButtonDismisses() async throws {
        let host = UIViewController()
        let window = Self.window(for: host)
        defer { window.isHidden = true }
        let viewer = ChatImageViewerController.present(
            from: host, gallery: Self.gallery(["a"], start: 0), file: { _ in .loading }, need: { _ in }, animated: false
        )
        #expect(host.presentedViewController === viewer)

        viewer.closeButton.sendActions(for: .primaryActionTriggered)
        await Self.settle { host.presentedViewController == nil }

        #expect(host.presentedViewController == nil)
    }

    @Test func presentingKeepsTheChatOnScreen() async throws {
        final class Host: UIViewController {
            var disappearCount = 0
            override func viewWillDisappear(_ animated: Bool) {
                super.viewWillDisappear(animated)
                disappearCount += 1
            }
        }
        let host = Host()
        let window = Self.window(for: host)
        defer { window.isHidden = true }

        let viewer = ChatImageViewerController.present(
            from: host, gallery: Self.gallery(["a"], start: 0), file: { _ in .loading }, need: { _ in }, animated: false
        )
        await Self.settle { viewer.viewIfLoaded?.window != nil }

        #expect(host.disappearCount == 0)
    }

    @Test func aShortSlowDragSpringsBackAFarOrFastOneDismisses() {
        #expect(ChatImageViewerController.shouldDismiss(offset: 40, velocity: 100) == false)
        #expect(ChatImageViewerController.shouldDismiss(offset: 160, velocity: 0))
        #expect(ChatImageViewerController.shouldDismiss(offset: 30, velocity: 1_200))
        #expect(ChatImageViewerController.shouldDismiss(offset: -160, velocity: -1_200) == false)
    }
}
