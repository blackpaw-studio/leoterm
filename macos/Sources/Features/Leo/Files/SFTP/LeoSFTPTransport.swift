import Darwin
import Foundation
import OSLog

/// One SFTP session over a `LeoSFTPChannel`: frames requests onto the
/// server's stdin and matches replies from its stdout back to the waiting
/// caller by request id, so any number of requests may be in flight.
///
/// A dedicated thread blocks in `read(2)` on the server's stdout; writes are
/// serialised on a private queue, so neither ever blocks the cooperative
/// pool. Once the session ends -- the server exits (EOF), a write fails, the
/// stream is malformed, or `close()` is called -- every pending and future
/// request fails with the same error (`.disconnected`, or `.protocolError`).
final class LeoSFTPTransport: @unchecked Sendable {
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")
    private static let readBufferSize = 64 * 1024

    private let channel: LeoSFTPChannel
    private let writeQueue = DispatchQueue(label: "com.mitchellh.ghostty.leo-sftp.write")

    /// Guards every field below.
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<LeoSFTPResponse, Error>] = [:]
    private var versionWaiter: CheckedContinuation<LeoSFTPServerVersion, Error>?
    private var hasVersion = false
    private var endError: LeoFileAccessError?

    init(channel: LeoSFTPChannel) {
        self.channel = channel
        // A write after the server died must fail with EPIPE, not kill the app.
        _ = fcntl(channel.toServer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = Thread { [self] in readLoop() }
        reader.name = "leo-sftp-reader"
        reader.start()
    }

    var isClosed: Bool { lock.withLock { endError != nil } }

    /// Sends `SSH_FXP_INIT` and waits for the server's `SSH_FXP_VERSION`.
    /// Call once, before any `send`.
    func handshake() async throws -> LeoSFTPServerVersion {
        try await withCheckedThrowingContinuation { continuation in
            let failure: LeoFileAccessError? = lock.withLock {
                if let endError { return endError }
                versionWaiter = continuation
                return nil
            }
            if let failure {
                continuation.resume(throwing: failure)
                return
            }
            enqueueWrite(LeoSFTPCodec.encodeInit())
        }
    }

    func send(_ request: LeoSFTPRequest) async throws -> LeoSFTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let registered: Result<UInt32, LeoFileAccessError> = lock.withLock {
                if let endError { return .failure(endError) }
                let id = nextID
                nextID &+= 1
                pending[id] = continuation
                return .success(id)
            }
            switch registered {
            case let .failure(error):
                continuation.resume(throwing: error)
            case let .success(id):
                enqueueWrite(LeoSFTPCodec.encode(request, id: id))
            }
        }
    }

    /// Ends the session: fails everything pending with `.disconnected`,
    /// closes the server's stdin and terminates it. Idempotent.
    func close() {
        end(with: .disconnected)
    }

    // MARK: - Writing

    private func enqueueWrite(_ packet: Data) {
        writeQueue.async { [self] in
            guard !isClosed else { return }
            if !Self.writeAll(packet, to: channel.toServer.fileDescriptor) {
                end(with: .disconnected)
            }
        }
    }

    private static func writeAll(_ packet: Data, to descriptor: Int32) -> Bool {
        packet.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    // MARK: - Reading

    private func readLoop() {
        let descriptor = channel.fromServer.fileDescriptor
        var framer = LeoSFTPFramer()
        var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
        var failure = LeoFileAccessError.disconnected
        reading: while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            framer.append(Data(buffer[0..<count]))
            do {
                while let payload = try framer.nextPacket() {
                    try deliver(payload)
                }
            } catch {
                failure = .protocolError(Self.describe(error))
                break reading
            }
        }
        end(with: failure)
        try? channel.fromServer.close()
    }

    private func deliver(_ payload: Data) throws {
        guard lock.withLock({ hasVersion }) else {
            let version = try LeoSFTPCodec.decodeVersion(payload)
            let waiter: CheckedContinuation<LeoSFTPServerVersion, Error>? = lock.withLock {
                hasVersion = true
                defer { versionWaiter = nil }
                return versionWaiter
            }
            waiter?.resume(returning: version)
            return
        }
        let reply = try LeoSFTPCodec.decodeReply(payload)
        let waiter = lock.withLock { pending.removeValue(forKey: reply.id) }
        guard let waiter else {
            Self.logger.error("sftp reply for unknown request id=\(reply.id)")
            return
        }
        waiter.resume(returning: reply.response)
    }

    // MARK: - Teardown

    private func end(with error: LeoFileAccessError) {
        let waiters: (requests: [CheckedContinuation<LeoSFTPResponse, Error>], version: CheckedContinuation<LeoSFTPServerVersion, Error>?)? = lock.withLock {
            guard endError == nil else { return nil }
            endError = error
            defer {
                pending.removeAll()
                versionWaiter = nil
            }
            return (Array(pending.values), versionWaiter)
        }
        guard let waiters else { return }
        Self.logger.log("sftp session ended error=\(String(describing: error), privacy: .public)")
        waiters.requests.forEach { $0.resume(throwing: error) }
        waiters.version?.resume(throwing: error)
        writeQueue.async { [channel] in try? channel.toServer.close() }
        channel.terminate()
    }

    /// What failed to decode. Anything other than a codec error is
    /// described by its own text, which is untrusted.
    static func describe(_ error: Error) -> LeoFileAccessReason {
        switch error {
        case let LeoSFTPCodecError.unexpectedType(type): "unexpected packet type \(type)"
        case let LeoSFTPCodecError.badLength(length): "bad packet length \(length)"
        case LeoSFTPCodecError.truncated: "truncated packet"
        default: .untrusted(String(describing: error))
        }
    }
}
