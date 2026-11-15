import Foundation

/// The shell bootstrap's "no sftp-server installed" line, matched on the raw
/// bounded stderr like `LeoSFTPSubsystemRejection` (D-422): server stderr is
/// untrusted, so bytes are judged line by line and never decoded as a whole.
/// Invalid UTF-8 elsewhere can neither hide the marker (leaving only an
/// opaque `<N bytes>` detail) nor let a longer message that merely contains
/// the marker authorize the plain "no supported SFTP server" answer.
enum LeoSFTPMissingServer {
    private static let marker = Array(LeoSSHCommand.missingSFTPServerMarker.utf8)
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    /// Whether any complete line of `stderr` is exactly the marker with an
    /// optional single trailing CR. When `isTruncated`, the last segment may
    /// be a prefix of a longer line and never counts.
    static func isMarked(in stderr: Data, isTruncated: Bool) -> Bool {
        let lines = stderr.split(separator: lineFeed, omittingEmptySubsequences: false)
        return lines.enumerated().contains { index, rawLine in
            guard !(isTruncated && index == lines.count - 1) else { return false }
            let line = rawLine.last == carriageReturn ? rawLine.dropLast() : rawLine
            return line.elementsEqual(marker)
        }
    }
}
