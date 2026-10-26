import AppKit
import ImageIO
import Testing
import WebKit

@testable import Ghostty

/// C4: real (`isTrusted`) mouse and keyboard input reaches a tab's web view
/// in every window it can sit in -- including the off-screen parking window
/// while another window is key. Events go straight to the web view, never
/// through the window server. WebKit re-sends keys the page leaves
/// unhandled through `NSApp.sendEvent`, so every test first makes a window
/// of its own key and main, and refuses to run while any other window is.
@MainActor
@Suite(.serialized, .enabled(if: LeoWKTestHost.hasWindowServer, "needs a window-server session"))
struct LeoAgentInputDeliveryTests {
    enum Placement: String, CaseIterable, CustomTestStringConvertible {
        case visibleNonKey
        case parked
        case reparentedWhileAnotherIsKey

        var testDescription: String { rawValue }
    }

    struct PageEvent: Decodable {
        let type: String
        let trusted: Bool
        let key: String?
        let meta: Bool
        let target: String
    }

    private static let fixture = """
    <title>Input</title>
    <style>body { margin: 0; background: #3366cc } input, button { font-size: 20px; margin: 20px }</style>
    <form id="form"><input id="field" aria-label="Field"><button id="press" type="button">Press</button></form>
    <script>
    window.events = [];
    for (const type of ['mousedown', 'mouseup', 'click', 'keydown', 'keyup', 'beforeinput', 'input', 'submit']) {
      addEventListener(type, event => {
        events.push({ type, trusted: event.isTrusted, key: event.key ?? null, meta: !!event.metaKey,
          target: event.target.id || event.target.nodeName });
        if (type === 'submit') event.preventDefault();
      }, true);
    }
    </script>
    """

    @available(macOS 14, *)
    @MainActor private final class Harness {
        static let size = CGSize(width: 640, height: 420)

        let page = LeoWKBrowserPage.fixture(["input": LeoAgentInputDeliveryTests.fixture])
        let parking = LeoAgentBrowserParkingWindow(size: Harness.size)
        let visible: NSWindow
        let other: NSWindow
        /// Takes key without ever being main.
        let panel: NSPanel
        private(set) var userInputs = 0
        /// The host's own windows, ordered out while a test needs no main
        /// window; never sent input.
        private var hostWindows: [NSWindow] = []

        init() {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            visible = NSWindow(
                contentRect: NSRect(origin: CGPoint(x: screen.minX + 40, y: screen.maxY - Harness.size.height - 80), size: Harness.size),
                styleMask: [.titled], backing: .buffered, defer: false)
            other = NSWindow(
                contentRect: NSRect(x: screen.minX + 80, y: screen.minY + 40, width: 240, height: 120),
                styleMask: [.titled], backing: .buffered, defer: false)
            panel = NSPanel(
                contentRect: NSRect(x: screen.minX + 80, y: screen.minY + 200, width: 240, height: 120),
                styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
            for window in [visible, other, panel] {
                window.isReleasedWhenClosed = false
                window.title = "LeoAgentInputDeliveryTests"
            }
            page.webView.onUserInput = { [unowned self] in userInputs += 1 }
        }

        /// Puts the page where `placement` says. The test host is the full
        /// app and active, with a window of its own; a window of this test
        /// takes key and main first, so nothing the test sends can reach it.
        func setUp(_ placement: Placement) async throws {
            if placement == .parked {
                try await makeOtherWindowKey()
                parking.park(page.webView)
            } else {
                page.webView.frame = visible.contentView!.bounds
                visible.contentView!.addSubview(page.webView)
                visible.orderFrontRegardless()
            }
            if placement == .visibleNonKey { try await makeOtherWindowKey() }
            _ = try await page.navigate(to: LeoWKFixtureServer.url("input"))
            if placement == .reparentedWhileAnotherIsKey {
                try await makeOtherWindowKey()
                parking.park(page.webView)
            }
            try requireNoForeignFocus()
        }

        private func makeOtherWindowKey() async throws {
            try await makeKey(other)
        }

        /// Activates the test host so `window` can be key and main.
        func makeKey(_ window: NSWindow) async throws {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for _ in 0..<50 where !(window.isKeyWindow && window.isMainWindow) {
                try await Task.sleep(for: .milliseconds(20))
            }
            print("C4-MEASURE window key: \(window.isKeyWindow), main: \(window.isMainWindow), app active: \(NSApp.isActive)")
        }

        /// Leaves the app with no main window, only this test's panel key.
        /// The host's launch window could be main, so it steps aside until
        /// `close`.
        func dropMainWindow() async throws {
            let ours = [visible, other, panel, parking].map(ObjectIdentifier.init)
            hostWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !ours.contains(ObjectIdentifier($0)) }
            for window in [visible, other] + hostWindows { window.orderOut(nil) }
            panel.makeKeyAndOrderFront(nil)
            for _ in 0..<50 where NSApp.mainWindow != nil || !panel.isKeyWindow {
                try await Task.sleep(for: .milliseconds(20))
            }
            let shown = NSApp.windows.filter(\.isVisible).map { "\($0.title) main-capable: \($0.canBecomeMain)" }
            print("C4-MEASURE no main window: key \(NSApp.keyWindow?.title ?? "none"), main \(NSApp.mainWindow?.title ?? "none"), shown \(shown)")
            try #require(panel.isKeyWindow && NSApp.mainWindow == nil)
        }

        /// Synthesized keys WebKit doesn't handle are re-sent through
        /// `NSApp.sendEvent`; only this test's windows may be key or main.
        func requireNoForeignFocus() throws {
            let ours = [visible, other, panel, parking].map(ObjectIdentifier.init)
            for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
                try #require(ours.contains(ObjectIdentifier(window)), "\"\(window.title)\" is key or main; not synthesizing input")
            }
        }

        func ref(_ prefix: String) async throws -> String {
            try #require(leoSnapshotRef(try await page.snapshot(), prefix))
        }

        func events() async throws -> [PageEvent] {
            let json = try await page.eval("return events.splice(0)")
            return try JSONDecoder().decode([PageEvent].self, from: Data(json.utf8))
        }

        func close() {
            page.webView.removeFromSuperview()
            for window in [visible, other, panel, parking] { window.close() }
            for window in hostWindows { window.orderFront(nil) }
        }
    }

    @available(macOS 14, *)
    @Test(arguments: Placement.allCases)
    func clickDeliversTrustedMouseEvents(_ placement: Placement) async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(placement)

        try await harness.page.click(ref: harness.ref(#"button "Press""#))

        let events = try await harness.events()
        #expect(events.map(\.type) == ["mousedown", "mouseup", "click"])
        #expect(events.allSatisfy { $0.trusted && $0.target == "press" })
    }

    @available(macOS 14, *)
    @Test(arguments: Placement.allCases)
    func typeDeliversTrustedKeysAndInput(_ placement: Placement) async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(placement)

        try await harness.page.type(ref: harness.ref(#"textbox "Field""#), text: "héllo 1", submit: false)

        #expect(try await harness.page.eval("return document.getElementById('field').value") == #""héllo 1""#)
        let events = try await harness.events()
        #expect(events.filter { $0.type == "keydown" }.compactMap(\.key) == ["h", "é", "l", "l", "o", " ", "1"])
        #expect(events.filter { $0.type == "input" }.count == 7)
        #expect(events.allSatisfy { $0.trusted })
    }

    @available(macOS 14, *)
    @Test(arguments: Placement.allCases)
    func enterSubmitsTheForm(_ placement: Placement) async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(placement)
        try await harness.page.type(ref: harness.ref(#"textbox "Field""#), text: "a", submit: false)
        _ = try await harness.events()

        try await harness.page.press(LeoSyntheticKey(key: "Enter"))

        let events = try await harness.events()
        #expect(events.first { $0.type == "keydown" }?.key == "Enter")
        #expect(events.contains { $0.type == "submit" && $0.trusted })
        #expect(events.allSatisfy { $0.trusted })
    }

    @available(macOS 14, *)
    @Test(arguments: Placement.allCases)
    func metaASelectsAll(_ placement: Placement) async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(placement)
        try await harness.page.type(ref: harness.ref(#"textbox "Field""#), text: "hello", submit: false)
        _ = try await harness.page.eval("const f = document.getElementById('field'); f.setSelectionRange(5, 5)")
        _ = try await harness.events()

        try await harness.page.press(LeoSyntheticKey(key: "a", modifiers: .command))

        let selection = try await harness.page.eval("const f = document.getElementById('field'); return [f.selectionStart, f.selectionEnd]")
        #expect(selection == "[0,5]")
        let keydown = try #require(try await harness.events().first { $0.type == "keydown" })
        #expect(keydown.key == "a" && keydown.meta && keydown.trusted)
    }

    @available(macOS 14, *)
    @Test(arguments: Placement.allCases)
    func screenshotShowsThePage(_ placement: Placement) async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(placement)

        let png = try await harness.page.screenshot(fullPage: false)

        let pixel = try Self.bottomRightPixel(png)
        print("C4-MEASURE screenshot \(placement) pixel: \(pixel)")
        #expect(abs(pixel.red - 0x33) <= 8 && abs(pixel.green - 0x66) <= 8 && abs(pixel.blue - 0xcc) <= 8)
    }

    @available(macOS 14, *)
    @Test(arguments: Placement.allCases)
    func animationFrameFiresWithin500ms(_ placement: Placement) async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(placement)

        let latency = try await harness.page.eval("""
        return await new Promise(resolve => {
          const start = performance.now();
          requestAnimationFrame(() => resolve(Math.round(performance.now() - start)));
          setTimeout(() => resolve(-1), 3000);
        })
        """)

        let timers = try await harness.page.eval("""
        const lag = ms => new Promise(resolve => {
          const start = performance.now();
          setTimeout(() => resolve(Math.round(performance.now() - start)), ms);
        });
        return [await lag(0), await lag(50)]
        """)
        print("C4-MEASURE rAF \(placement): \(latency) ms (-1 = none within 3 s); setTimeout(0), (50): \(timers) ms")
        let ms = try #require(Int(latency))
        #expect(ms >= 0 && ms < 500)
    }

    enum MainWindow: String, CaseIterable, CustomTestStringConvertible {
        case present
        /// Leo in the background: the app's own key monitor then offers
        /// every key to its keybindings and the main menu.
        case absent

        var testDescription: String { rawValue }
    }

    /// WebKit re-sends a key the page leaves unhandled through
    /// `NSApp.sendEvent`. None may reach an event monitor -- the app's
    /// shortcuts and keybindings are one -- a key equivalent, a menu or a
    /// window. Harmless keys go first, and each must vanish before the
    /// next is sent.
    @available(macOS 14, *)
    @Test(arguments: MainWindow.allCases)
    func resentKeysNeverReachTheAppOrItsWindows(_ main: MainWindow) async throws {
        // Monitors run in an unspecified order: probe on both sides of any
        // the page's input might install.
        let early = KeyProbe()
        defer { early.remove() }
        let harness = Harness()
        defer { harness.close() }
        let late = KeyProbe()
        defer { late.remove() }
        try await harness.setUp(.parked)
        if main == .absent { try await harness.dropMainWindow() }
        let keyWindow = try #require(NSApp.keyWindow)
        let recorder = KeyRecorder(frame: keyWindow.contentView!.bounds)
        keyWindow.contentView!.addSubview(recorder)
        keyWindow.makeFirstResponder(recorder)
        try harness.requireNoForeignFocus()

        let keys: [LeoSyntheticKey] = [
            .init(key: "F19"), .init(key: "Escape"), .init(key: "F19", modifiers: [.command, .control, .option]),
            .init(key: "a", modifiers: .command), .init(key: "w", modifiers: .command),
            .init(key: "q", modifiers: .command), .init(key: ",", modifiers: .command),
        ]
        for key in keys {
            try await harness.page.press(key)
            let reached = early.received + late.received + recorder.received
            try #require(reached.isEmpty, "\(key.key) (modifiers \(key.modifiers.rawValue)) reached \(reached)")
        }
    }

    /// A local key monitor that records and swallows every key it sees.
    @MainActor private final class KeyProbe {
        private(set) var received: [String] = []
        private var monitor: Any?

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.received.append("monitor \(event.keyCode)") }
                return nil
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    /// Records the keys that reach it, and swallows key equivalents so none
    /// reaches the app's menus.
    private final class KeyRecorder: NSView {
        private(set) var received: [String] = []

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            received.append("keyDown \(event.keyCode)")
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            received.append("performKeyEquivalent \(event.keyCode)")
            return true
        }
    }

    /// Every event stays the agent's until the page has handled it, however
    /// much it types.
    @available(macOS 14, *)
    @Test func longTypingDoesNotTakeOver() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(.parked)
        let started = ContinuousClock.now

        try await harness.page.type(ref: harness.ref(#"textbox "Field""#), text: String(repeating: "abcdefghij", count: 100), submit: false)

        print("C4-MEASURE typed 1000 characters in \(ContinuousClock.now - started)")
        #expect(harness.userInputs == 0)
        #expect(try await harness.page.eval("return document.getElementById('field').value.length") == "1000")
    }

    @available(macOS 14, *)
    @Test func cancellingTypeStopsFurtherCharacters() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(.parked)
        let ref = try await harness.ref(#"textbox "Field""#)
        let length = "return document.getElementById('field').value.length"
        let typing = Task { try await harness.page.type(ref: ref, text: String(repeating: "x", count: 200), submit: false) }
        for _ in 0..<500 {
            if try await Int(harness.page.eval(length)) ?? 0 >= 5 { break }
        }

        typing.cancel()
        let result = await typing.result

        let typed = try #require(Int(try await harness.page.eval(length)))
        _ = try await harness.page.eval("return 0")
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(typed < 200)
        #expect(try await Int(harness.page.eval(length)) == typed)
    }

    /// Focus the agent moves stays in the page: Tab into a control asks
    /// for the web view to become first responder, and Tab past the last
    /// one hands focus to the window's next key view. Either would take it
    /// from the user's terminal beside the browser pane.
    @available(macOS 14, *)
    @Test func agentTabNeverMovesFocusOutOfTheWebView() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(.visibleNonKey)
        let content = harness.visible.contentView!
        let third = content.bounds.width / 3
        harness.page.webView.frame = NSRect(x: 0, y: 0, width: third, height: content.bounds.height)
        let nextField = NSTextField(frame: NSRect(x: third, y: 0, width: third, height: 24))
        let textView = NSTextView(frame: NSRect(x: 2 * third, y: 0, width: third, height: content.bounds.height))
        for view in [nextField, textView] { content.addSubview(view) }
        // The key view loop runs browser, field, the user's view.
        harness.page.webView.nextKeyView = nextField
        nextField.nextKeyView = textView
        textView.nextKeyView = harness.page.webView
        try await harness.makeKey(harness.visible)
        harness.visible.makeFirstResponder(textView)
        try harness.requireNoForeignFocus()
        print("C4-MEASURE before Tab: window first responder \(String(describing: harness.visible.firstResponder))")

        for press in 1...4 {
            try await harness.page.press(LeoSyntheticKey(key: "Tab"))
            let active = try await harness.page.eval("return document.activeElement?.id ?? null")
            print("C4-MEASURE Tab \(press): page focus \(active), window first responder \(String(describing: harness.visible.firstResponder))")
            #expect(harness.visible.firstResponder === textView, "after Tab \(press)")
        }
    }

    @available(macOS 14, *)
    @Test func syntheticInputDoesNotTakeOver() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(.parked)

        try await harness.page.click(ref: harness.ref(#"button "Press""#))
        try await harness.page.type(ref: harness.ref(#"textbox "Field""#), text: "x", submit: true)
        try await harness.page.press(LeoSyntheticKey(key: "a", modifiers: .command))
        try await harness.page.press(LeoSyntheticKey(key: "F19"))

        #expect(harness.userInputs == 0)
    }

    @available(macOS 14, *)
    @Test func directMouseDownTakesOver() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.setUp(.parked)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 300, y: 50), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.parking.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        harness.page.webView.mouseDown(with: event)

        #expect(harness.userInputs == 1)
    }

    private struct Pixel: CustomStringConvertible {
        let red: Int, green: Int, blue: Int
        var description: String { String(format: "#%02x%02x%02x", red, green, blue) }
    }

    /// The sRGB colour a few pixels in from the screenshot's bottom-right
    /// corner, clear of the fixture's form.
    private static func bottomRightPixel(_ png: Data) throws -> Pixel {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -(image.width - 10), y: -10, width: image.width, height: image.height))
        return Pixel(red: Int(rgba[0]), green: Int(rgba[1]), blue: Int(rgba[2]))
    }
}
