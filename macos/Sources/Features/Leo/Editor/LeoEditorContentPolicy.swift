import Foundation

/// Why a file opened read-only; the pane shows `notice`.
enum LeoEditorReadOnlyReason: Equatable, Sendable {
    case tooLarge(size: UInt64, limit: UInt64)
    case binary
    /// Shown with invalid bytes replaced, so saving it would corrupt it.
    case notUTF8

    var notice: String {
        switch self {
        case let .tooLarge(_, limit):
            "This file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(clamping: limit), countStyle: .file)), so it’s read-only."
        case .binary: "This file looks binary, so it’s read-only."
        case .notUTF8: "This file isn’t UTF-8 text, so it’s read-only."
        }
    }
}

/// A file's bytes as the editor shows them.
struct LeoEditorContent: Equatable, Sendable {
    let text: String
    let readOnlyReason: LeoEditorReadOnlyReason?

    /// What saving writes. Exact for editable content: the text is valid
    /// UTF-8 decoded as is (a BOM and `\r\n` survive).
    func encoded() -> Data { Data(text.utf8) }
}

/// The binary / large-file guard. Files up to `editableLimit` bytes of
/// UTF-8 text are editable; larger ones, binary ones and non-UTF-8 ones
/// open read-only; files over `readLimit` don't open at all (`read` fails
/// with `.tooLarge`).
struct LeoEditorContentPolicy: Equatable, Sendable {
    static let `default` = LeoEditorContentPolicy(editableLimit: 5_000_000, readLimit: 20_000_000)

    /// git's heuristic: a NUL in the first 8000 bytes means binary.
    static let binarySniffLength = 8000

    let editableLimit: UInt64
    let readLimit: UInt64

    /// Decoding replaces invalid bytes with U+FFFD, so the text encodes
    /// back to exactly `data` only when `data` was valid UTF-8 (unlike
    /// `String(data:encoding:)`, this keeps a BOM).
    func evaluate(_ data: Data) -> LeoEditorContent {
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        if data.prefix(Self.binarySniffLength).contains(0) {
            return LeoEditorContent(text: text, readOnlyReason: .binary)
        }
        guard Data(text.utf8) == data else { return LeoEditorContent(text: text, readOnlyReason: .notUTF8) }
        let size = UInt64(data.count)
        return LeoEditorContent(text: text, readOnlyReason: size > editableLimit ? .tooLarge(size: size, limit: editableLimit) : nil)
    }
}
