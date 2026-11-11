import Darwin
import Dispatch
import Foundation
import LeoKit

/// File and folder change events for dev mode, from a `DispatchSource` on a
/// descriptor opened with `O_EVTONLY` (it doesn't keep a volume busy). The
/// descriptor is closed by the source's cancel handler, never earlier.
struct LeoPluginDispatchFileEvents: LeoPluginFileEventSource {
    private let queue = DispatchQueue(label: "studio.blackpaw.leo.plugin-dev-watch")

    private final class Watch: LeoPluginTimerHandle, @unchecked Sendable {
        private let source: DispatchSourceFileSystemObject
        init(source: DispatchSourceFileSystemObject) { self.source = source }
        func cancel() { source.cancel() }
    }

    func watch(_ url: URL, handler: @escaping @Sendable () -> Void) -> (any LeoPluginTimerHandle)? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .delete, .rename, .link], queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return Watch(source: source)
    }
}
