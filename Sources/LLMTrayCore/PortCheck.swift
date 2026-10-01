import Darwin
import Foundation

/// Whether the API's TCP port is already taken by another process, before
/// the server is first started on it (the setup wizard). A bind and a
/// connect, not `lsof`/`ps`: those can't run in the App Store's sandbox.
public enum PortCheck {
    /// Ports the API may use: above the privileged range.
    public static let validRange = 1024...65535

    /// Something holds `port` on this Mac: a listener answers on
    /// localhost, or the port can't be bound (as the server would bind it).
    public static func isInUse(_ port: Int) -> Bool {
        guard validRange.contains(port) else { return true }
        if acceptsConnections(port: port, ipv6: false) || acceptsConnections(port: port, ipv6: true) { return true }
        // SO_REUSEADDR: a port the server just let go of (TIME_WAIT) isn't
        // taken. Loopback and every interface: the server binds one or the
        // other (Settings › Allow connections from the local network).
        return !canBind(port: port, loopbackOnly: true) || !canBind(port: port, loopbackOnly: false)
    }

    /// The first free port after `port` (wrapping round the valid range),
    /// or nil after `limit` tries. `isInUse` is injectable for the tests.
    public static func nextFree(after port: Int, limit: Int = 200, isInUse: (Int) -> Bool = PortCheck.isInUse) -> Int? {
        var candidate = port
        for _ in 0..<limit {
            candidate = candidate >= validRange.upperBound || candidate < validRange.lowerBound ? validRange.lowerBound : candidate + 1
            if candidate == port { return nil }
            if !isInUse(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Sockets

    private static func canBind(port: Int, loopbackOnly: Bool) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }   // can't tell: don't claim it's taken
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = ipv4(port: port, loopback: loopbackOnly)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 || errno != EADDRINUSE
    }

    /// A non-blocking connect with a short wait: a listener on localhost
    /// answers at once, a closed port refuses at once.
    private static func acceptsConnections(port: Int, ipv6: Bool, timeoutMs: Int32 = 250) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let result: Int32
        if ipv6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port)).bigEndian
            address.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = ipv4(port: port, loopback: true)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }

    private static func ipv4(port: Int, loopback: Bool) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = (loopback ? INADDR_LOOPBACK : INADDR_ANY).bigEndian
        return address
    }
}
