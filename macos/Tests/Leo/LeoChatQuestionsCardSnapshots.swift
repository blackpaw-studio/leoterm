import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

private let snapshotOutputDirectory = ProcessInfo.processInfo.environment["LEO_CARD_SNAPSHOTS"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }

/// Renders the questions card in every state, light and dark, to PNGs for
/// a human to inspect. Only runs with `LEO_CARD_SNAPSHOTS=<output dir>`.
@MainActor @Suite(.enabled(if: snapshotOutputDirectory != nil), .timeLimit(.minutes(2)))
struct LeoChatQuestionsCardSnapshots {
    private static let columnWidth: CGFloat = 400
    private static let alpha = LeoAgentID(host: .local, name: "alpha")

    enum Fixture: String, CaseIterable, Sendable {
        case open, partial, complete, tooLong, refused, inFlight, answered, terminal, dismissed, timedOut, expired
    }

    private static let questions = [
        LeoChatQuestion(
            id: "q1", header: "Library", question: "Which HTTP library should the client use?",
            options: [
                LeoChatOption(value: "URLSession", label: "URLSession", description: "Built in, no dependency to maintain."),
                LeoChatOption(value: "Alamofire", label: "Alamofire", description: "Richer retry and interceptor support, but one more package to keep current across both apps."),
                LeoChatOption(value: "Custom", label: "Custom"),
            ]
        ),
        LeoChatQuestion(
            id: "q2", header: "Scope", question: "What should the change cover?", multi: true,
            options: [
                LeoChatOption(value: "Mac app", label: "Mac app"),
                LeoChatOption(value: "iOS app", label: "iOS app", description: "Needs a UIKit cell as well."),
                LeoChatOption(value: "Docs", label: "Docs"),
            ]
        ),
        LeoChatQuestion(
            id: "q3", header: "", question: "Anything the agent should know first?", options: [LeoChatOption(value: "No", label: "No")]
        ),
    ]

    private func card(state: String, answer: LeoChatAnswer? = nil, closedReason: String? = nil) throws -> LeoChatMessage {
        LeoChatMessage(
            id: "01", agent: "alpha", direction: .outbound, kind: .ask, text: "The agent has questions", state: state, answer: answer,
            ts: Date(timeIntervalSince1970: 1_800_000_000), input: try LeoChatInput(questions: Self.questions), closedReason: closedReason
        )
    }

    private func model(client: FakeChatClient, message: LeoChatMessage) async -> LeoChatPaneModel {
        await client.enqueuePage([message])
        let model = LeoChatPaneModel(
            client: client, host: .local, recorder: FakeVoiceRecorder(),
            attachmentDirectory: FileManager.default.temporaryDirectory.appending(path: "leo-card-snapshots-\(UUID().uuidString)")
        )
        await model.show(Self.alpha)
        return model
    }

    private func fillPartly(_ model: LeoChatPaneModel) {
        model.chooseQuestion(messageID: "01", questionID: "q1", value: "URLSession")
        model.chooseQuestion(messageID: "01", questionID: "q2", value: "Mac app")
        model.chooseQuestion(messageID: "01", questionID: "q2", value: "Docs")
    }

    private func fillCompletely(_ model: LeoChatPaneModel) {
        fillPartly(model)
        model.setQuestionText(messageID: "01", questionID: "q3", "Use the existing socket client.")
    }

    /// The model showing `fixture`'s card, driven only through the pane model.
    private func prepare(_ fixture: Fixture, client: FakeChatClient) async throws -> LeoChatPaneModel {
        let answered = LeoChatAnswer(answers: [
            "q1": .choice("URLSession"), "q2": LeoChatAnswer(values: ["Mac app", "Docs"]),
            "q3": LeoChatAnswer(values: [], text: "Use the existing socket client."),
        ])
        switch fixture {
        case .open:
            return await model(client: client, message: try card(state: "open"))
        case .partial:
            let model = await model(client: client, message: try card(state: "open"))
            fillPartly(model)
            return model
        case .complete, .refused, .inFlight:
            let model = await model(client: client, message: try card(state: "open"))
            fillCompletely(model)
            if fixture == .refused {
                await client.setQuestionsResult(.failure(LeoChatAnswerError.invalid("answers don't match the questions")))
                await model.submitQuestions(messageID: "01")
            } else if fixture == .inFlight {
                await client.holdQuestionAnswers()
                Task { await model.submitQuestions(messageID: "01") }
                await client.waitForQuestionAnswers(1)
            }
            return model
        case .tooLong:
            let model = await model(client: client, message: try card(state: "open"))
            fillPartly(model)
            model.setQuestionText(messageID: "01", questionID: "q3", String(repeating: "word ", count: 900))
            return model
        case .answered:
            return await model(client: client, message: try card(state: "answered", answer: answered))
        case .terminal:
            return await model(client: client, message: try card(state: "answered", answer: LeoChatAnswer(values: ["terminal"])))
        case .dismissed:
            return await model(client: client, message: try card(state: "expired", closedReason: "dismissed"))
        case .timedOut:
            return await model(client: client, message: try card(state: "expired", closedReason: "timeout"))
        case .expired:
            return await model(client: client, message: try card(state: "expired", closedReason: "withdrawn"))
        }
    }

    @Test(arguments: Fixture.allCases) func capture(_ fixture: Fixture) async throws {
        let directory = try #require(snapshotOutputDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = FakeChatClient()
        let model = try await prepare(fixture, client: client)
        let message = try #require(model.timeline.message(id: "01"))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let window = hostedWindow(message: message, model: model, appearance: appearance)
            let png = try #require(Self.png(of: window))
            try png.write(to: directory.appending(path: "\(fixture.rawValue)-\(name).png"))
            if fixture == .partial, name == "light" { try Self.writeKeyViewLoops(of: window, to: directory) }
            window.close()
        }
        await client.releaseQuestionAnswers()
    }

    private func hostedWindow(message: LeoChatMessage, model: LeoChatPaneModel, appearance: NSAppearance.Name) -> NSWindow {
        let row = LeoChatMessageRow(message: message, position: .single, chat: model)
            .padding(12)
            .frame(width: Self.columnWidth, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: row)
        let size = host.fittingSize
        let window = KeyableWindow(
            contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderBack(nil)
        window.makeKey()
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return window
    }

    private static func png(of window: NSWindow) -> Data? {
        guard let view = window.contentView, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * retinaScale, pixelsHigh: Int(view.bounds.height) * retinaScale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static let retinaScale = 2

    /// A borderless window that can be key, so controls draw as active.
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// Tab order as the system has it, then with full keyboard access on
    /// (the app-domain `AppleKeyboardUIMode` bit), which is what lets Tab
    /// reach buttons, radio rows and checkboxes.
    private static func writeKeyViewLoops(of window: NSWindow, to directory: URL) throws {
        let key = "AppleKeyboardUIMode"
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { original.map { defaults.set($0, forKey: key) } ?? defaults.removeObject(forKey: key) }
        var report = ["system setting\n" + keyViewLoop(of: window)]
        defaults.set(2, forKey: key)
        report.append("full keyboard access forced on\n" + keyViewLoop(of: window))
        try report.joined(separator: "\n").write(to: directory.appending(path: "key-view-loop.txt"), atomically: true, encoding: .utf8)
    }

    /// The views Tab visits, in order, as the window's key-view loop has them.
    private static func keyViewLoop(of window: NSWindow) -> String {
        window.recalculateKeyViewLoop()
        var lines = ["NSApp.isFullKeyboardAccessEnabled = \(NSApp.isFullKeyboardAccessEnabled)"]
        var visited: [NSView] = []
        var view = window.contentView?.nextValidKeyView
        while let current = view, !visited.contains(where: { $0 === current }), visited.count < 40 {
            visited.append(current)
            lines.append("\(String(describing: type(of: current)).prefix(60)) label=\(current.accessibilityLabel() ?? "-")")
            view = current.nextValidKeyView
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
