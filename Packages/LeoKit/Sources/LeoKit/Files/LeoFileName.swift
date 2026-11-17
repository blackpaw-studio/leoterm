import Foundation

/// Rules for a single file name crossing between the Mac and a workspace.
public enum LeoFileName {
    /// One path component that is safe to open or create: non-empty, not
    /// `.`/`..`, and free of `/`, NUL and control characters (a NUL would
    /// truncate the C path; a newline or escape could forge text around it).
    public static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// "a.txt" -> "a 2.txt"; a name without an extension (".env",
    /// "Makefile") gets the number at its end.
    public static func numbered(_ name: String, _ number: Int) -> String {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else { return "\(name) \(number)" }
        return "\((name as NSString).deletingPathExtension) \(number).\(pathExtension)"
    }

    /// `.<name>.leo-<random>.tmp` beside `path`: where a write or create
    /// stages its bytes, so the final rename never crosses a filesystem
    /// boundary. The name part is capped so the staging name stays within
    /// NAME_MAX (255 bytes) for any target name.
    public static func stagingPath(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // swiftlint:disable:next optional_data_string_conversion
        let stem = name.utf8.count <= stagingStemLimit ? name : String(decoding: name.utf8.prefix(stagingStemLimit), as: UTF8.self)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return (directory as NSString).appendingPathComponent(".\(stem)\(stagingInfix)\(token)\(stagingSuffix)")
    }

    /// Whether `name` (one path component) is a name `stagingPath` makes:
    /// a leading dot, a non-empty stem, then `.leo-` + 32 lowercase hex +
    /// `.tmp`. Nothing else is ever removed as a leftover staging file.
    public static func isStagingName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        let tail = stagingInfix.utf8.count + stagingTokenLength + stagingSuffix.utf8.count
        guard isSafeComponent(name), bytes.first == UInt8(ascii: "."), bytes.count > tail + 1,
              name.hasSuffix(stagingSuffix) else { return false }
        let infixStart = bytes.count - tail
        let token = bytes[(infixStart + stagingInfix.utf8.count)..<(bytes.count - stagingSuffix.utf8.count)]
        return bytes[infixStart..<(infixStart + stagingInfix.utf8.count)].elementsEqual(stagingInfix.utf8) &&
            token.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    private static let stagingInfix = ".leo-"
    private static let stagingSuffix = ".tmp"
    private static let stagingTokenLength = 32

    /// 255 - 42 bytes of `.` + `.leo-<32>.tmp`, less 3 in case truncating
    /// mid-character leaves a replacement character (3 bytes in UTF-8).
    private static var stagingStemLimit: Int { 210 }
}
