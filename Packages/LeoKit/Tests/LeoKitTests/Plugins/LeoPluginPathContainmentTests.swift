import Foundation
import Testing

@testable import LeoKit

struct LeoPluginPathContainmentTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func fileInsideFolderIsContained() {
        #expect(LeoPluginPathContainment.isContained(resolved: url("/p/plugin/dist/main.js"), in: url("/p/plugin")))
    }

    @Test func folderItselfIsNotAFile() {
        #expect(!LeoPluginPathContainment.isContained(resolved: url("/p/plugin"), in: url("/p/plugin")))
    }

    @Test func siblingWithSharedPrefixIsNotContained() {
        #expect(!LeoPluginPathContainment.isContained(resolved: url("/p/plugin-evil/main.js"), in: url("/p/plugin")))
    }

    @Test func dotDotThatEscapesIsNotContained() {
        #expect(!LeoPluginPathContainment.isContained(resolved: url("/p/plugin/../other/main.js"), in: url("/p/plugin")))
    }

    @Test func dotDotThatStaysInsideIsContained() {
        #expect(LeoPluginPathContainment.isContained(resolved: url("/p/plugin/a/../main.js"), in: url("/p/plugin")))
    }

    @Test func trailingSlashOnFolderDoesNotMatter() {
        #expect(LeoPluginPathContainment.isContained(resolved: url("/p/plugin/main.js"), in: URL(fileURLWithPath: "/p/plugin/", isDirectory: true)))
    }

    @Test func nonFileURLsAreNotContained() {
        let web = URL(string: "https://example.com/p/plugin/main.js")!
        #expect(!LeoPluginPathContainment.isContained(resolved: web, in: url("/p/plugin")))
    }

    @Test func symlinkedEscapeIsCaughtOnceResolved() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("leo-contain-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let plugin = root.appendingPathComponent("plugin")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: plugin, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("secret.js"))
        try fm.createSymbolicLink(at: plugin.appendingPathComponent("link.js"), withDestinationURL: outside.appendingPathComponent("secret.js"))
        let resolved = plugin.appendingPathComponent("link.js").resolvingSymlinksInPath()
        #expect(!LeoPluginPathContainment.isContained(resolved: resolved, in: plugin.resolvingSymlinksInPath()))
    }
}
