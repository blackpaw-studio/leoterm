import Foundation

/// The `LeoPluginHost` helper's whole job: read commands from the socket,
/// run them in one `LeoPluginJSRuntime`, write the runtime's requests back.
///
/// Single-threaded and synchronous. Each command is followed by a
/// ``LeoPluginWire/doneFrame`` so the app knows when the handler returned.
/// Returns an exit code: 0 when the app closed its end (or stopped reading),
/// 1 on a protocol violation or if the runtime couldn't start.
public enum LeoPluginHostLoop {
    public static func run(fd: Int32) -> Int32 {
        let output = FrameWriter(fd: fd)
        guard let runtime = try? LeoPluginJSRuntime(send: { output.send($0) }) else { return 1 }
        let decoder = JSONDecoder()
        while true {
            if output.broken { return 0 }
            let frame: Data
            do {
                guard let next = try LeoPluginWire.readFrame(from: fd, limit: LeoPluginWire.maxAppToHostBytes) else { return 0 }
                frame = next
            } catch {
                return 1
            }
            guard let command = try? decoder.decode(LeoPluginHostCommand.self, from: frame) else { return 1 }
            switch command {
            case .load(let source):
                do {
                    try runtime.load(source: source)
                } catch {
                    output.send(.handlerError(source: "load", message: "\(error)"))
                }
            case .deliver(let event):
                runtime.deliver(event)
            }
            output.writeDone()
        }
    }

    private final class FrameWriter {
        private let fd: Int32
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return encoder
        }()
        private(set) var broken = false

        init(fd: Int32) { self.fd = fd }

        func send(_ request: LeoPluginHostRequest) {
            guard let payload = try? encoder.encode(request) else { return }
            if payload.count <= LeoPluginWire.maxHostToAppBytes {
                write(payload)
            } else if let fallback = try? encoder.encode(
                LeoPluginHostRequest.handlerError(source: "bridge", message: "response too large")) {
                write(fallback)
            }
        }

        func writeDone() { write(LeoPluginWire.doneFrame) }

        private func write(_ payload: Data) {
            guard !broken, let framed = try? LeoPluginWire.encode(payload, limit: LeoPluginWire.maxHostToAppBytes) else { return }
            do { try LeoPluginWire.writeAll(framed, to: fd) } catch { broken = true }
        }
    }
}
