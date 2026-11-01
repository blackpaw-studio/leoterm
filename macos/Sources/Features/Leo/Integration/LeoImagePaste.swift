import AppKit

/// Remote image paste (Mac only: the iOS terminal has no paste). Claude Code
/// on a remote machine reads *that* machine's clipboard, so an image pasted
/// into a remote agent is uploaded like a dropped file and its path typed.
enum LeoImagePaste {
    enum Key: Equatable, CaseIterable {
        case controlV
        case commandV
    }

    enum SurfaceKind: Equatable, CaseIterable {
        case remoteAgent
        case localAgent
        case dispatch
        case plain
    }

    enum Decision: Equatable {
        case uploadImage
        /// Today's behaviour for the key: Ctrl+V sends 0x16 to the pty, ⌘V
        /// does a text paste.
        case passThrough
    }

    static func decide(key: Key, hasImage: Bool, hasText: Bool, surface: SurfaceKind) -> Decision {
        guard surface == .remoteAgent, hasImage else { return .passThrough }
        switch key {
        case .controlV: return .uploadImage
        // ⌘V keeps pasting text whenever there is any; the image only wins
        // when it is all the clipboard holds.
        case .commandV: return hasText ? .passThrough : .uploadImage
        }
    }
}
