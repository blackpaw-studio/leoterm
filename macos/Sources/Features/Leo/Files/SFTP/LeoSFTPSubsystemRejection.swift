import Foundation

/// OpenSSH's diagnostic when sshd rejects `-s ... sftp`, matched on the raw
/// bounded stderr. Server stderr is untrusted: bytes are judged line by line
/// and never decoded as a whole, so invalid UTF-8 (or a character cut at the
/// capture limit) elsewhere can neither hide a complete canonical line nor
/// let a subsystem's own longer message authorize the shell bootstrap.
enum LeoSFTPSubsystemRejection {
    private static let prefix = Array("subsystem request failed on channel ".utf8)
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let asciiDigits: ClosedRange<UInt8> = 0x30...0x39

    /// Whether any complete line of `stderr` is exactly the canonical
    /// rejection: the ASCII prefix, one or more ASCII digits, and an
    /// optional single trailing CR. When `isTruncated`, the last segment
    /// may be a prefix of a longer line and never counts; a preceding
    /// newline proves a line ended even when later stderr was cut.
    static func isCanonical(in stderr: Data, isTruncated: Bool) -> Bool {
        let lines = stderr.split(separator: lineFeed, omittingEmptySubsequences: false)
        return lines.enumerated().contains { index, line in
            !(isTruncated && index == lines.count - 1) && isCanonicalLine(line)
        }
    }

    private static func isCanonicalLine(_ rawLine: Data) -> Bool {
        let line = rawLine.last == carriageReturn ? rawLine.dropLast() : rawLine
        guard line.starts(with: prefix) else { return false }
        let channel = line.dropFirst(prefix.count)
        return !channel.isEmpty && channel.allSatisfy(asciiDigits.contains)
    }
}
