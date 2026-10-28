import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing

@testable import Ghostty
@testable import LeoKit

extension LeoAppEventQueueTests {
/// B-318: ⌘C copies text dragged over in a chat bubble while an agent's
/// terminal surface shares the window: covered by the chat (it never had
/// the keyboard; the composer has it) or beside it (it had the keyboard
/// until the drag). The drag and the ⌘C go through the window's and the
/// app's real event paths, so the surface's key-equivalent handling and
/// the app's Edit menu both see the key, as they do in the app. Only the
/// menu copies the selection, and only if its sync gave Copy ⌘C
/// (`LeoStandardEditShortcut`).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct LeoChatCopyTests {
    @Test(arguments: ChatCopyTerminal.allCases)
    func commandCCopiesSelectedChatText(terminal: ChatCopyTerminal) async throws {
        let harness = try await ChatCopyHarness()
        defer { harness.close() }
        try await harness.focus(terminal)

        try harness.dragAcrossMessage()
        let copied = try harness.pressCommandC()

        #expect(copied != ChatCopyHarness.sentinel, "⌘C left the pasteboard untouched")
        #expect(copied.map { !$0.isEmpty && ChatCopyHarness.needle.contains($0) } == true, "copied \(copied ?? "nil")")
    }
}
}

/// Where the agent's terminal surface is when the chat text is selected.
enum ChatCopyTerminal: CaseIterable, Sendable {
    /// Under the chat, never given the keyboard: the composer has it.
    case coveredByChat
    /// Beside the chat, holding the keyboard until the drag.
    case besideChatWithKeyboard
}

/// A key window holding the real chat pane (one message) and a real
/// terminal surface running a stand-in command.
@MainActor
private final class ChatCopyHarness {
    static let needle = "copyable needle text"
    static let sentinel = "B-318 sentinel"
    private static let chatFrame = NSRect(x: 300, y: 0, width: 400, height: 480)

    let window: NSWindow
    let session = LeoWindowSession(defaults: LeoInMemoryDefaults())
    let surface: Ghostty.SurfaceView
    private let savedPasteboard = NSPasteboard.general.string(forType: .string)

    init() async throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app, "needs the app's Ghostty.App")
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        surface = Ghostty.SurfaceView(app, baseConfig: config)
        let client = FakeChatClient()
        await client.enqueuePage([chatMessage("m1", text: Self.needle, at: 1)])
        let chat = LeoChatPaneModel(
            clients: [.local: client], recorder: FakeVoiceRecorder(),
            attachmentDirectory: FileManager.default.temporaryDirectory.appending(path: "leo-chat-copy-\(UUID().uuidString)")
        )
        let row = LeoAgentRow(host: .local, name: "alpha", template: nil, status: .running, activity: .idle, actionDetail: nil)
        let pane = LeoChatPane(row: row, chat: chat, session: session, viewer: session.chatViewer, close: {})
        let host = NSHostingView(rootView: pane)
        host.frame = Self.chatFrame
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.chatFrame.maxX, height: Self.chatFrame.height))
        content.addSubview(surface)
        content.addSubview(host)
        window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        try await Self.settle { self.messageField != nil }
        try #require(messageField != nil, "the message never rendered")
    }

    /// The selectable text field SwiftUI puts over the message's text.
    var messageField: NSTextField? {
        Self.views(NSTextField.self, in: window.contentView)
            .first { $0.isSelectable && !$0.isEditable && $0.stringValue.contains(Self.needle) }
    }

    private var composerHasFocus: Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField else { return false }
        return field.isEditable
    }

    func focus(_ terminal: ChatCopyTerminal) async throws {
        switch terminal {
        case .coveredByChat:
            surface.frame = window.contentView?.bounds ?? .zero
            session.requestChatFocus()
            try await Self.settle { self.composerHasFocus }
            try #require(composerHasFocus, "the composer never took focus")
        case .besideChatWithKeyboard:
            surface.frame = NSRect(x: 0, y: 0, width: Self.chatFrame.minX, height: Self.chatFrame.height)
            try #require(window.makeFirstResponder(surface))
        }
    }

    /// Drags from the first to the last character of the message, through
    /// `NSWindow.sendEvent`, as the window server would deliver it.
    func dragAcrossMessage() throws {
        let field = try #require(messageField)
        let rect = field.convert(field.bounds, to: nil)
        let start = NSPoint(x: rect.minX + 3, y: rect.midY)
        let end = NSPoint(x: rect.maxX - 1, y: rect.midY)
        let steps = 8
        let drags = (1...steps).map { step in
            NSPoint(x: start.x + (end.x - start.x) * CGFloat(step) / CGFloat(steps), y: start.y)
        }
        let events = [(NSEvent.EventType.leftMouseDown, start)]
            + drags.map { (.leftMouseDragged, $0) }
            + [(.leftMouseUp, end)]
        for (type, point) in events {
            window.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
    }

    /// Presses ⌘C through `NSApp.sendEvent` and returns what it leaves on
    /// the general pasteboard.
    func pressCommandC() throws -> String? {
        try #require(NSApp.keyWindow === window, "the test window must be key for ⌘C to reach it")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.sentinel, forType: .string)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_C))))
        }
        return pasteboard.string(forType: .string)
    }

    func close() {
        surface.removeFromSuperview()
        window.close()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let savedPasteboard { pasteboard.setString(savedPasteboard, forType: .string) }
    }

    private static func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func views<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
        guard let view else { return [] }
        return ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }
}
