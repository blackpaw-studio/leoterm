import Darwin
import Foundation

/// The real `LeoPortProbing`: plain BSD sockets on `127.0.0.1`. Glue over
/// syscalls, so it has no unit tests of its own (binding real ports is what
/// the injected prober exists to avoid).
struct LeoLoopbackPortProber: LeoPortProbing {
    func isFree(_ port: Int) -> Bool {
        guard let socket = Self.makeSocket() else { return false }
        defer { Darwin.close(socket) }
        var address = Self.loopbackAddress(port: port)
        return Self.bind(socket, &address) == 0
    }

    func isListening(_ port: Int) -> Bool {
        guard let socket = Self.makeSocket() else { return false }
        defer { Darwin.close(socket) }
        var address = Self.loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func pickFreePort() throws -> Int {
        guard let socket = Self.makeSocket() else { throw LeoPortForwardError.noFreePort }
        defer { Darwin.close(socket) }
        var address = Self.loopbackAddress(port: 0)
        guard Self.bind(socket, &address) == 0 else { throw LeoPortForwardError.noFreePort }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socket, $0, &length) }
        }
        guard result == 0 else { throw LeoPortForwardError.noFreePort }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private static func makeSocket() -> Int32? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        return socket >= 0 ? socket : nil
    }

    private static func loopbackAddress(port: Int) -> sockaddr_in {
        let port = (0...65_535).contains(port) ? port : 0
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        return address
    }

    private static func bind(_ socket: Int32, _ address: inout sockaddr_in) -> Int32 {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}
