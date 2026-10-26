import AppKit
import Carbon.HIToolbox

/// A key to press: a DOM key name (`Enter`, `ArrowUp`, `F5`) or a single
/// character, plus modifiers. Stand-in for LeoKit's parsed key combo
/// until the executor is wired to this adapter.
struct LeoSyntheticKey: Equatable {
    let key: String
    var modifiers: NSEvent.ModifierFlags = []
}

/// Builds the real `NSEvent`s the agent's clicks and keys become, and
/// delivers them straight to a web view -- never through the window server
/// or `NSWindow.sendEvent`, so they reach a view in a window that is not
/// key or not on screen, and no other window can receive them. WebKit
/// turns them into `isTrusted` DOM events.
///
/// An event is the agent's, by (type, timestamp), from just before it
/// reaches the view until the page has handled it, so the web view can
/// tell it from the user's input however much the agent sends.
///
/// WebKit re-sends a key the page didn't handle through `NSApp.sendEvent`,
/// where event monitors, key equivalents, menus and the key window would
/// see it -- the user's terminal, or Quit. `LeoApplication` hands each of
/// ours back here before any of them; the standard editing key
/// equivalents (select all, copy, ...) go to its own web view, which is
/// how `Meta+a` selects all while the view is not in the key window.
@MainActor final class LeoSyntheticInput {
    private struct Stamp: Hashable {
        let type: UInt
        let timestamp: TimeInterval

        init(_ event: NSEvent) {
            type = event.type.rawValue
            timestamp = event.timestamp
        }
    }

    private final class WeakView {
        weak var view: NSView?

        init(_ view: NSView) { self.view = view }
    }

    /// Re-sent key equivalents that act on the web view they were meant for.
    private static let editingActions: [String: Selector] = [
        "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
        "x": #selector(NSText.cut(_:)), "v": #selector(NSText.paste(_:)),
        "z": Selector(("undo:")), "Z": Selector(("redo:")),
    ]

    /// The events in flight, each with the view it was delivered to.
    private var pending: [Stamp: WeakView] = [:]
    private var lastTimestamp: TimeInterval = 0
    private var eventNumber = 0

    init(application: LeoApplication) {
        application.routeResentKeys(to: self)
    }

    func isSynthetic(_ event: NSEvent) -> Bool {
        pending[Stamp(event)] != nil
    }

    /// Hover, press and release at `point` in `view`'s coordinates.
    func click(at point: CGPoint, in view: NSView) -> [NSEvent] {
        let location = view.convert(point, to: nil)
        let windowNumber = view.window?.windowNumber ?? 0
        return [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp].compactMap { type in
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: nextTimestamp(),
                windowNumber: windowNumber, context: nil, eventNumber: nextEventNumber(),
                clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
    }

    /// Down and up for `key`; nil when it names no key.
    func press(_ key: LeoSyntheticKey, in view: NSView) -> [NSEvent]? {
        guard let spec = Self.spec(for: key.key) else { return nil }
        let modifiers = key.modifiers.union(spec.modifiers)
        let characters = modifiers.contains(.control) ? Self.controlCharacter(spec.characters) : spec.characters
        let windowNumber = view.window?.windowNumber ?? 0
        return [NSEvent.EventType.keyDown, .keyUp].compactMap { type in
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: nextTimestamp(),
                windowNumber: windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: spec.characters, isARepeat: false, keyCode: spec.keyCode)
        }
    }

    /// Down and up per character of `text`.
    func type(_ text: String, in view: NSView) -> [NSEvent] {
        text.flatMap { press(LeoSyntheticKey(key: String($0)), in: view) ?? [] }
    }

    /// Hands each event to `view` the way its window would, then waits for
    /// `settle` to confirm the page has handled it. Once the task is
    /// cancelled it sends nothing more and throws `CancellationError`.
    func deliver(_ events: [NSEvent], to view: NSView, settle: () async throws -> Void) async throws {
        for event in events {
            try Task.checkCancellation()
            let stamp = Stamp(event)
            pending[stamp] = WeakView(view)
            defer { pending[stamp] = nil }
            dispatch(event, to: view)
            try await settle()
            try Task.checkCancellation()
        }
    }

    /// True when `event` is one of ours coming back from WebKit, after
    /// applying its editing key equivalent, if any, to its own web view.
    func absorbResent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let entry = pending[Stamp(event)] else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.subtracting(.shift) == .command,
           let key = event.charactersIgnoringModifiers,
           let action = Self.editingActions[flags.contains(.shift) ? key.uppercased() : key],
           let view = entry.view, view.responds(to: action) {
            NSApp.sendAction(action, to: view, from: nil)
        }
        return true
    }

    private func dispatch(_ event: NSEvent, to view: NSView) {
        switch event.type {
        case .mouseMoved: view.mouseMoved(with: event)
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .keyDown: view.keyDown(with: event)
        case .keyUp: view.keyUp(with: event)
        default: break
        }
    }

    // MARK: Identity

    private func nextTimestamp() -> TimeInterval {
        lastTimestamp = max(ProcessInfo.processInfo.systemUptime, lastTimestamp.nextUp)
        return lastTimestamp
    }

    private func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }

    // MARK: Keys

    private struct KeySpec {
        let keyCode: UInt16
        let characters: String
        var modifiers: NSEvent.ModifierFlags = []
    }

    /// Key code used for characters the US layout has no key for; WebKit
    /// reports its DOM `code` as unidentified.
    private static let unmappedKeyCode: UInt16 = 0x42

    private static func function(_ scalar: Int) -> String {
        String(Character(UnicodeScalar(scalar)!))
    }

    private static let namedKeys: [String: KeySpec] = {
        var keys: [String: KeySpec] = [
            "Enter": .init(keyCode: UInt16(kVK_Return), characters: "\r"),
            "Tab": .init(keyCode: UInt16(kVK_Tab), characters: "\t"),
            "Escape": .init(keyCode: UInt16(kVK_Escape), characters: "\u{1b}"),
            "Backspace": .init(keyCode: UInt16(kVK_Delete), characters: "\u{7f}"),
            "Space": .init(keyCode: UInt16(kVK_Space), characters: " "),
            "Delete": .init(keyCode: UInt16(kVK_ForwardDelete), characters: function(NSDeleteFunctionKey), modifiers: .function),
            "Home": .init(keyCode: UInt16(kVK_Home), characters: function(NSHomeFunctionKey), modifiers: .function),
            "End": .init(keyCode: UInt16(kVK_End), characters: function(NSEndFunctionKey), modifiers: .function),
            "PageUp": .init(keyCode: UInt16(kVK_PageUp), characters: function(NSPageUpFunctionKey), modifiers: .function),
            "PageDown": .init(keyCode: UInt16(kVK_PageDown), characters: function(NSPageDownFunctionKey), modifiers: .function),
            "ArrowUp": .init(keyCode: UInt16(kVK_UpArrow), characters: function(NSUpArrowFunctionKey), modifiers: [.function, .numericPad]),
            "ArrowDown": .init(keyCode: UInt16(kVK_DownArrow), characters: function(NSDownArrowFunctionKey), modifiers: [.function, .numericPad]),
            "ArrowLeft": .init(keyCode: UInt16(kVK_LeftArrow), characters: function(NSLeftArrowFunctionKey), modifiers: [.function, .numericPad]),
            "ArrowRight": .init(keyCode: UInt16(kVK_RightArrow), characters: function(NSRightArrowFunctionKey), modifiers: [.function, .numericPad]),
        ]
        let functionCodes = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, code) in functionCodes.enumerated() {
            keys["F\(index + 1)"] = .init(keyCode: UInt16(code), characters: function(NSF1FunctionKey + index), modifiers: .function)
        }
        return keys
    }()

    /// US-layout keys for printable characters; the second string holds
    /// each key's shifted characters.
    private static let characterKeys: [Character: KeySpec] = {
        let rows: [(Int, String, String)] = [
            (kVK_ANSI_A, "a", "A"), (kVK_ANSI_B, "b", "B"), (kVK_ANSI_C, "c", "C"), (kVK_ANSI_D, "d", "D"),
            (kVK_ANSI_E, "e", "E"), (kVK_ANSI_F, "f", "F"), (kVK_ANSI_G, "g", "G"), (kVK_ANSI_H, "h", "H"),
            (kVK_ANSI_I, "i", "I"), (kVK_ANSI_J, "j", "J"), (kVK_ANSI_K, "k", "K"), (kVK_ANSI_L, "l", "L"),
            (kVK_ANSI_M, "m", "M"), (kVK_ANSI_N, "n", "N"), (kVK_ANSI_O, "o", "O"), (kVK_ANSI_P, "p", "P"),
            (kVK_ANSI_Q, "q", "Q"), (kVK_ANSI_R, "r", "R"), (kVK_ANSI_S, "s", "S"), (kVK_ANSI_T, "t", "T"),
            (kVK_ANSI_U, "u", "U"), (kVK_ANSI_V, "v", "V"), (kVK_ANSI_W, "w", "W"), (kVK_ANSI_X, "x", "X"),
            (kVK_ANSI_Y, "y", "Y"), (kVK_ANSI_Z, "z", "Z"),
            (kVK_ANSI_1, "1", "!"), (kVK_ANSI_2, "2", "@"), (kVK_ANSI_3, "3", "#"), (kVK_ANSI_4, "4", "$"),
            (kVK_ANSI_5, "5", "%"), (kVK_ANSI_6, "6", "^"), (kVK_ANSI_7, "7", "&"), (kVK_ANSI_8, "8", "*"),
            (kVK_ANSI_9, "9", "("), (kVK_ANSI_0, "0", ")"),
            (kVK_ANSI_Minus, "-", "_"), (kVK_ANSI_Equal, "=", "+"), (kVK_ANSI_LeftBracket, "[", "{"),
            (kVK_ANSI_RightBracket, "]", "}"), (kVK_ANSI_Backslash, "\\", "|"), (kVK_ANSI_Semicolon, ";", ":"),
            (kVK_ANSI_Quote, "'", "\""), (kVK_ANSI_Comma, ",", "<"), (kVK_ANSI_Period, ".", ">"),
            (kVK_ANSI_Slash, "/", "?"), (kVK_ANSI_Grave, "`", "~"),
        ]
        var keys: [Character: KeySpec] = [" ": .init(keyCode: UInt16(kVK_Space), characters: " ")]
        for (code, plain, shifted) in rows {
            keys[Character(plain)] = .init(keyCode: UInt16(code), characters: plain)
            keys[Character(shifted)] = .init(keyCode: UInt16(code), characters: shifted, modifiers: .shift)
        }
        keys["\n"] = namedKeys["Enter"]
        keys["\r"] = namedKeys["Enter"]
        keys["\t"] = namedKeys["Tab"]
        return keys
    }()

    private static func spec(for key: String) -> KeySpec? {
        if let named = namedKeys[key] { return named }
        guard key.count == 1, let character = key.first else { return nil }
        return characterKeys[character] ?? KeySpec(keyCode: unmappedKeyCode, characters: key)
    }

    /// What Control turns a letter key into (`a` → U+0001).
    private static func controlCharacter(_ characters: String) -> String {
        guard let scalar = characters.lowercased().unicodeScalars.first, ("a"..."z").contains(scalar) else { return characters }
        return String(Character(UnicodeScalar(scalar.value - 0x60)!))
    }
}
