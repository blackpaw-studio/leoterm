import Foundation
import Testing

@testable import Ghostty

struct LeoInstallPathsTests {
    private let paths = LeoInstallPaths(
        home: URL(fileURLWithPath: "/home/test", isDirectory: true),
        bundleURL: URL(fileURLWithPath: "/Applications/Leo.app")
    )

    @Test func layoutMatchesTheMarkerContract() {
        #expect(paths.markerURL.path == "/home/test/.leo/state/managed.json")
        #expect(paths.selfLinkURL.path == "/home/test/.leo/app/bin/leo")
        #expect(paths.tmuxURL(version: "3.6a")?.path == "/home/test/.leo/app/tmux/3.6a/tmux")
        #expect(paths.bundledLeo.path == "/Applications/Leo.app/Contents/Helpers/leo")
        #expect(paths.bundledTmux.path == "/Applications/Leo.app/Contents/Helpers/tmux")
        #expect(paths.bundledTerminfo.path == "/Applications/Leo.app/Contents/Resources/terminfo")
        #expect(paths.localBinLeo.path == "/home/test/.local/bin/leo")
        #expect(paths.localBinLeoBackup.path == "/home/test/.local/bin/leo.pre-leoapp")
    }

    @Test(arguments: ["", ".", "..", "../x", "3.6/../..", "a/b", "3 6", "3.6a\n", ".hidden"])
    func refusesTmuxVersionsThatCouldEscapeTheRoot(version: String) {
        #expect(paths.tmuxURL(version: version) == nil)
    }

    @Test(arguments: ["3.6a", "3.7", "next-3.8", "3.6a-rc_1"])
    func acceptsRealTmuxVersions(version: String) {
        #expect(paths.tmuxURL(version: version)?.lastPathComponent == "tmux")
    }
}
