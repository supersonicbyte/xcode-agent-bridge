import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct SocketError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A blocking Unix domain stream socket with send and receive timeouts.
public final class UnixSocket: @unchecked Sendable {
    public let descriptor: Int32

    public init(path: String, timeout: TimeInterval = 10) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("Couldn't create a socket (\(String(cString: strerror(errno)))).") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            throw SocketError("The socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw SocketError("Couldn't connect to \(path) (\(reason)).")
        }
        var interval = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        descriptor = fd
    }

    deinit { close(descriptor) }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw SocketError("Couldn't write to the socket (\(String(cString: strerror(errno)))).")
                }
                offset += sent
            }
        }
    }

    /// Reads whatever is available, blocking up to the timeout. Empty data means the peer closed.
    public func read(maximum: Int = 65_536) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximum)
        while true {
            let count = recv(descriptor, &buffer, maximum, 0)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError("Timed out waiting for a reply.") }
                throw SocketError("Couldn't read from the socket (\(String(cString: strerror(errno)))).")
            }
            return Data(buffer.prefix(count))
        }
    }
}
