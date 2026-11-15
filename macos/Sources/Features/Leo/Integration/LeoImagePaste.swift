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

    /// Whether the pasteboard holds an image. Asks the pasteboard without
    /// decoding it. A copied file is not one: Finder also puts the file's
    /// icon on the pasteboard as a TIFF, which must not be uploaded.
    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.ghosttyFileURLs.isEmpty && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Whether the pasteboard holds text a normal ⌘V would paste.
    static func hasText(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSString.self], options: nil)
    }

    /// The pasteboard image as PNG data: PNG is passed through untouched,
    /// anything else NSImage reads (TIFF first) is re-encoded.
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        let source = pasteboard.data(forType: .tiff) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation
        return source
            .flatMap(NSBitmapImageRep.init(data:))
            .flatMap { $0.representation(using: .png, properties: [:]) }
    }

    /// Where pasted images land on the remote host.
    static func scratchDirectory(home: String) -> String {
        (home as NSString).appendingPathComponent(".cache/leo/paste")
    }

    /// `leo-paste-yyyyMMdd-HHmmss-SSS.png`, in UTC so the name doesn't depend
    /// on the Mac's zone.
    static func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "leo-paste-\(formatter.string(from: date)).png"
    }
}
