import Foundation
import Testing

@testable import Ghostty

struct LeoManagedMarkerTests {
    private static let bundleID = "studio.blackpaw.leo.macos"
    private static let home = URL(fileURLWithPath: "/home/test", isDirectory: true)
    private static let paths = LeoInstallPaths(home: home, bundleURL: URL(fileURLWithPath: "/Applications/Leo.app"))
    private static let markerPath = "/home/test/.leo/state/managed.json"

    private static let marker = LeoManagedMarker(
        bundleID: bundleID,
        launchdLabel: "studio.blackpaw.leo.daemon",
        selfPath: "/home/test/.leo/app/bin/leo",
        tmuxPath: "/home/test/.leo/app/tmux/3.6a/tmux",
        env: nil
    )

    private func makeStore(_ fileSystem: LeoInMemoryFileSystem = LeoInMemoryFileSystem()) -> (LeoMarkerStore, LeoInMemoryFileSystem) {
        (LeoMarkerStore(paths: Self.paths, fileSystem: fileSystem, bundleID: Self.bundleID), fileSystem)
    }

    // MARK: codec

    @Test func encodesExactlyTheContractKeys() throws {
        let data = try Self.marker.encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "manager", "bundle_id", "launchd_label", "self_path", "tmux_path"])
        #expect(object["version"] as? Int == 1)
        #expect(object["manager"] as? String == "Leo.app")
        #expect(object["self_path"] as? String == "/home/test/.leo/app/bin/leo")
    }

    @Test func encodesOptionalEnvWhenPresent() throws {
        var marker = Self.marker
        marker.env = ["PATH": "/a:/b", "TERMINFO_DIRS": "/t"]
        let object = try #require(try JSONSerialization.jsonObject(with: marker.encoded()) as? [String: Any])
        #expect(object["env"] as? [String: String] == ["PATH": "/a:/b", "TERMINFO_DIRS": "/t"])
    }

    @Test func encodingIsStableAndDoesNotEscapeSlashes() throws {
        let text = try #require(String(bytes: Self.marker.encoded(), encoding: .utf8))
        #expect(text.contains("\"self_path\" : \"/home/test/.leo/app/bin/leo\""))
        #expect(try Self.marker.encoded() == Self.marker.encoded())
    }

    @Test func roundTripsThroughDecode() throws {
        var marker = Self.marker
        marker.env = ["PATH": "/a"]
        #expect(LeoManagedMarker.decode(try marker.encoded(), ownBundleID: Self.bundleID) == .ours(marker))
    }

    @Test func decodesAMarkerFromAnotherBundleAsForeignKeepingItsPaths() throws {
        let foreign = LeoManagedMarker(
            bundleID: "studio.blackpaw.leo.macos.debug",
            launchdLabel: "studio.blackpaw.leo.daemon.debug",
            selfPath: "/home/test/.leo/app/bin/leo",
            tmuxPath: "/home/test/.leo/app/tmux/3.6a/tmux",
            env: nil
        )
        #expect(LeoManagedMarker.decode(try foreign.encoded(), ownBundleID: Self.bundleID) == .foreign(bundleID: "studio.blackpaw.leo.macos.debug", marker: foreign))
    }

    @Test(arguments: [
        ("not json", "malformed JSON"),
        ("[]", "malformed JSON"),
        (#"{"version":2,"manager":"Leo.app","bundle_id":"b","launchd_label":"l","self_path":"/s","tmux_path":"/t"}"#, "unsupported version 2"),
        (#"{"manager":"Leo.app","bundle_id":"b","launchd_label":"l","self_path":"/s","tmux_path":"/t"}"#, "malformed JSON"),
        (#"{"version":1,"manager":"Leo.app","launchd_label":"l","self_path":"/s","tmux_path":"/t"}"#, "missing bundle_id"),
        (#"{"version":1,"manager":"Leo.app","bundle_id":"b","launchd_label":"","self_path":"/s","tmux_path":"/t"}"#, "missing launchd_label"),
        (#"{"version":1,"manager":"Leo.app","bundle_id":"b","launchd_label":"l","self_path":"leo","tmux_path":"/t"}"#, "self_path must be absolute: leo"),
        (#"{"version":1,"manager":"Leo.app","bundle_id":"b","launchd_label":"l","self_path":"/s","tmux_path":"~/t"}"#, "tmux_path must be absolute: ~/t"),
        (#"{"version":1,"manager":"Leo.app","bundle_id":"b","launchd_label":"l","self_path":"/s","tmux_path":"/t","env":{"A":1}}"#, "malformed JSON")
    ])
    func rejectsInvalidMarkers(json: String, reason: String) {
        #expect(LeoManagedMarker.decode(Data(json.utf8), ownBundleID: Self.bundleID) == .invalid(reason))
    }

    // MARK: store

    @Test func readsAbsentWhenThereIsNoMarker() {
        let (store, _) = makeStore()
        #expect(store.read() == .absent)
    }

    @Test func writesTheMarkerAtomicallyWithMode0600AndCreatesTheStateDirectoryOnce() throws {
        let (store, fileSystem) = makeStore()

        try store.write(Self.marker)

        #expect(fileSystem.ops == [
            .createDirectory("/home/test/.leo/state", mode: 0o700),
            .write("/home/test/.leo/state/.managed.json.t1.tmp", mode: 0o600),
            .rename("/home/test/.leo/state/.managed.json.t1.tmp", Self.markerPath)
        ])
        #expect(fileSystem.mode(at: URL(fileURLWithPath: Self.markerPath)) == 0o600)
        #expect(store.read() == .ours(Self.marker))
    }

    @Test func leavesAnExistingStateDirectoryAlone() throws {
        let fileSystem = LeoInMemoryFileSystem()
        fileSystem.addDirectory("/home/test/.leo/state", mode: 0o755)
        let (store, _) = makeStore(fileSystem)

        try store.write(Self.marker)

        #expect(fileSystem.ops == [
            .write("/home/test/.leo/state/.managed.json.t1.tmp", mode: 0o600),
            .rename("/home/test/.leo/state/.managed.json.t1.tmp", Self.markerPath)
        ])
    }

    @Test func overwritingReplacesTheMarkerThroughRename() throws {
        let (store, fileSystem) = makeStore()
        try store.write(Self.marker)
        var updated = Self.marker
        updated.tmuxPath = "/home/test/.leo/app/tmux/3.7/tmux"
        fileSystem.clearLog()

        try store.write(updated)

        #expect(fileSystem.ops.map(\.kindName) == ["write", "rename"])
        #expect(store.read() == .ours(updated))
    }

    @Test func refusesToWriteARelativePathAndTouchesNothing() {
        let (store, fileSystem) = makeStore()
        var marker = Self.marker
        marker.selfPath = "bin/leo"

        #expect(throws: LeoMarkerError.relativePath(field: "self_path", value: "bin/leo")) { try store.write(marker) }
        #expect(fileSystem.ops.isEmpty)
    }

    @Test func aFailedWriteLeavesTheOldMarkerAndSurfacesTheError() throws {
        let (store, fileSystem) = makeStore()
        try store.write(Self.marker)
        fileSystem.failNext("write", at: Self.markerPath)

        #expect(throws: LeoFileSystemError.self) { try store.write(Self.marker) }
        #expect(store.read() == .ours(Self.marker))
    }

    @Test func removeUnlinksOnlyTheMarker() throws {
        let (store, fileSystem) = makeStore()
        try store.write(Self.marker)
        fileSystem.addFile("/home/test/.leo/state/leo.sock")
        fileSystem.clearLog()

        try store.remove()

        #expect(fileSystem.ops == [.remove(Self.markerPath)])
        #expect(store.read() == .absent)
        #expect(fileSystem.kind(at: URL(fileURLWithPath: "/home/test/.leo/state/leo.sock")) == .file)
    }

    @Test func removeIsANoOpWhenAbsent() throws {
        let (store, fileSystem) = makeStore()
        try store.remove()
        #expect(fileSystem.ops.isEmpty)
    }

    @Test func aGroupOrWorldWritableMarkerReadsInvalidBecauseLeoIgnoresIt() throws {
        let fileSystem = LeoInMemoryFileSystem()
        fileSystem.addFile(Self.markerPath, try Self.marker.encoded(), mode: 0o664)
        let (store, _) = makeStore(fileSystem)

        #expect(store.read() == .invalid("marker is group- or world-writable (0664)"))
    }

    @Test func aMarkerThatIsNotARegularFileReadsInvalid() {
        let fileSystem = LeoInMemoryFileSystem()
        fileSystem.addSymlink(Self.markerPath, to: "/elsewhere/managed.json")
        let (store, _) = makeStore(fileSystem)

        #expect(store.read() == .invalid("marker is not a regular file"))
    }

    @Test func anUnreadableMarkerReadsInvalid() throws {
        let fileSystem = LeoInMemoryFileSystem()
        fileSystem.addFile(Self.markerPath, try Self.marker.encoded(), mode: 0o600)
        fileSystem.failNext("read", at: Self.markerPath, code: EACCES)
        let (store, _) = makeStore(fileSystem)

        #expect(store.read() == .invalid("cannot read marker: read \(Self.markerPath): Permission denied"))
    }
}

private extension LeoFileOp {
    var kindName: String {
        switch self {
        case .createDirectory: "createDirectory"
        case .write: "write"
        case .rename: "rename"
        case .remove: "remove"
        case .symlink: "symlink"
        case .copy: "copy"
        case .move: "move"
        case .moveNoReplace: "moveNoReplace"
        case .trash: "trash"
        }
    }
}
