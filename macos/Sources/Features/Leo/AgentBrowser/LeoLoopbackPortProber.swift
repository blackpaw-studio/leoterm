import Darwin
import Foundation

/// The real `LeoPortProbing`: plain BSD sockets on the loopback addresses.
/// Glue over syscalls, so it has no unit tests of its own (binding real
/// ports is what the injected prober exists to avoid).
struct LeoLoopbackPortProber: LeoPortProbing {
    private static let pickAttempts = 16

    func isFree(_ port: Int) -> Bool {
        Self.isFree(port, family: .ipv4) && (!isIPv6LoopbackAvailable() || Self.isFree(port, family: .ipv6))
    }

    func isIPv6LoopbackAvailable() -> Bool {
        guard let socket = Self.makeSocket(.ipv6) else { return false }
        defer { Darwin.close(socket) }
        return Self.bind(socket, .ipv6, port: 0)
    }

    func isListening(_ port: Int) -> Bool {
        guard (1...65_535).contains(port), let socket = Self.makeSocket(.ipv4) else { return false }
        defer { Darwin.close(socket) }
        var address = Self.ipv4Address(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    func pickFreePort() throws -> Int {
        let ipv6 = isIPv6LoopbackAvailable()
        for _ in 0..<Self.pickAttempts {
            guard let port = Self.ephemeralIPv4Port() else { break }
            if !ipv6 || Self.isFree(port, family: .ipv6) { return port }
        }
        throw LeoPortForwardError.noFreePort
    }

    // MARK: - Sockets

    private static func isFree(_ port: Int, family: LeoLoopbackAddress) -> Bool {
        guard (1...65_535).contains(port), let socket = makeSocket(family) else { return false }
        defer { Darwin.close(socket) }
        return bind(socket, family, port: port)
    }

    /// Binds port 0 on 127.0.0.1 and reads back what the OS chose.
    private static func ephemeralIPv4Port() -> Int? {
        guard let socket = makeSocket(.ipv4) else { return nil }
        defer { Darwin.close(socket) }
        guard bind(socket, .ipv4, port: 0) else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socket, $0, &length) }
        }
        return result == 0 ? Int(UInt16(bigEndian: bound.sin_port)) : nil
    }

    private static func makeSocket(_ family: LeoLoopbackAddress) -> Int32? {
        let socket = Darwin.socket(family == .ipv4 ? AF_INET : AF_INET6, SOCK_STREAM, 0)
        return socket >= 0 ? socket : nil
    }

    private static func ipv4Address(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        return address
    }

    private static func ipv6Address(port: Int) -> sockaddr_in6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(truncatingIfNeeded: port).bigEndian
        address.sin6_addr = in6addr_loopback
        return address
    }

    private static func bind(_ socket: Int32, _ family: LeoLoopbackAddress, port: Int) -> Bool {
        switch family {
        case .ipv4:
            var address = ipv4Address(port: port)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            } == 0
        case .ipv6:
            var address = ipv6Address(port: port)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            } == 0
        }
    }
}
