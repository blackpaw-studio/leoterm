import Foundation
import Testing

@testable import LeoKit

private let sha = String(repeating: "c", count: 40)

private func manifestJSON(id: String, name: String = "Demo") -> String {
    #"{"id":"\#(id)","name":"\#(name)","version":"1.0.0","apiVersion":1,"main":"main.js"}"#
}

private struct Sandbox {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("leo-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func plugin(at path: String, manifest: String, main: String? = "1") throws -> URL {
        let dir = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("leo-plugin.json"))
        if let main { try Data(main.utf8).write(to: dir.appendingPathComponent("main.js")) }
        return dir
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct LeoPluginDiscoveryTests {
    @Test func findsBundledInstalledAndDevPlugins() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.plugin(at: "bundle/studio.blackpaw.one", manifest: manifestJSON(id: "studio.blackpaw.one"))
        try box.plugin(at: "installed/studio.blackpaw.two/\(sha)", manifest: manifestJSON(id: "studio.blackpaw.two"))
        let dev = try box.plugin(at: "dev", manifest: manifestJSON(id: "studio.blackpaw.three"))

        let found = LeoPluginDiscovery.discover(
            bundledRoot: box.root.appendingPathComponent("bundle"), installedRoot: box.root.appendingPathComponent("installed"),
            installed: ["studio.blackpaw.two": sha], devFolders: [dev])

        #expect(found.plugins.compactMap(\.manifest?.id).sorted() == ["studio.blackpaw.one", "studio.blackpaw.three", "studio.blackpaw.two"])
        #expect(found.plugin(id: "studio.blackpaw.one")?.origin == .bundled)
        #expect(found.plugin(id: "studio.blackpaw.two")?.origin == .installed(sha: sha))
        #expect(found.plugin(id: "studio.blackpaw.three")?.origin == .dev)
    }

    @Test func anInvalidManifestIsListedAsRefusedWithItsReason() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.plugin(at: "bundle/broken", manifest: #"{"id":"nope"}"#)

        let found = LeoPluginDiscovery.discover(
            bundledRoot: box.root.appendingPathComponent("bundle"), installedRoot: box.root.appendingPathComponent("none"),
            installed: [:], devFolders: [])

        let entry = try #require(found.plugins.first)
        #expect(entry.manifest == nil)
        #expect(entry.refusal?.isEmpty == false)
        #expect(entry.directory.lastPathComponent == "broken")
    }

    @Test func aDuplicateIdResolvesDevThenInstalledThenBundled() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let id = "studio.blackpaw.dup"
        try box.plugin(at: "bundle/\(id)", manifest: manifestJSON(id: id, name: "Bundled"))
        try box.plugin(at: "installed/\(id)/\(sha)", manifest: manifestJSON(id: id, name: "Installed"))
        let dev = try box.plugin(at: "dev", manifest: manifestJSON(id: id, name: "Dev"))
        let bundleRoot = box.root.appendingPathComponent("bundle")
        let installedRoot = box.root.appendingPathComponent("installed")

        let all = LeoPluginDiscovery.discover(bundledRoot: bundleRoot, installedRoot: installedRoot, installed: [id: sha], devFolders: [dev])
        #expect(all.plugins.count == 1)
        #expect(all.plugin(id: id)?.manifest?.name == "Dev")
        #expect(all.shadowed.count == 2)

        let noDev = LeoPluginDiscovery.discover(bundledRoot: bundleRoot, installedRoot: installedRoot, installed: [id: sha], devFolders: [])
        #expect(noDev.plugin(id: id)?.manifest?.name == "Installed")
        let onlyBundled = LeoPluginDiscovery.discover(bundledRoot: bundleRoot, installedRoot: installedRoot, installed: [:], devFolders: [])
        #expect(onlyBundled.plugin(id: id)?.manifest?.name == "Bundled")
    }

    @Test func aManifestWhoseIdDisagreesWithItsFolderIsRefused() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        try box.plugin(at: "installed/studio.blackpaw.a/\(sha)", manifest: manifestJSON(id: "studio.blackpaw.b"))

        let found = LeoPluginDiscovery.discover(
            bundledRoot: nil, installedRoot: box.root.appendingPathComponent("installed"),
            installed: ["studio.blackpaw.a": sha], devFolders: [])

        #expect(found.plugins.count == 1)
        #expect(found.plugins.first?.manifest == nil)
        #expect(found.plugins.first?.refusal?.contains("studio.blackpaw.a") == true)
    }

    @Test func anInstalledIdWithNoFolderIsListedAsRefused() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let found = LeoPluginDiscovery.discover(
            bundledRoot: nil, installedRoot: box.root.appendingPathComponent("installed"),
            installed: ["studio.blackpaw.gone": sha], devFolders: [])
        #expect(found.plugins.first?.refusal != nil)
    }

    @Test func aSymlinkedManifestEscapingTheFolderIsRefused() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let outside = box.root.appendingPathComponent("outside.json")
        try Data(manifestJSON(id: "studio.blackpaw.evil").utf8).write(to: outside)
        let dir = box.root.appendingPathComponent("bundle/studio.blackpaw.evil")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("leo-plugin.json"), withDestinationURL: outside)

        let found = LeoPluginDiscovery.discover(
            bundledRoot: box.root.appendingPathComponent("bundle"), installedRoot: box.root.appendingPathComponent("x"),
            installed: [:], devFolders: [])
        #expect(found.plugins.first?.manifest == nil)
    }

    @Test func readMainRefusesAnEscapingSymlinkAndReturnsTheBundleOtherwise() throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let dir = try box.plugin(at: "p", manifest: manifestJSON(id: "studio.blackpaw.p"), main: "leo.render('x',{})")
        #expect(try LeoPluginBundleFile.readMain("main.js", in: dir) == "leo.render('x',{})")

        let outside = box.root.appendingPathComponent("secret.js")
        try Data("steal()".utf8).write(to: outside)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("main.js"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("main.js"), withDestinationURL: outside)
        #expect(throws: LeoPluginBundleFile.Refusal.self) { try LeoPluginBundleFile.readMain("main.js", in: dir) }
    }
}
