import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)

    /// A TCP proxy in front of a Zenoh router that forwards the router-to-client
    /// direction at a fixed byte rate, like a slow Wi-Fi link. The router's queue
    /// toward a session behind it fills up, so the router drops droppable
    /// messages (best effort or `CongestionControl::Drop`) the way it does for a
    /// slow device. The client-to-router direction is not throttled.
    final class ThrottlingTCPProxy: @unchecked Sendable {
        let port: UInt16
        var locator: String { "tcp/127.0.0.1:\(port)" }

        private let listener: Int32
        private let upstreamHost: String
        private let upstreamPort: String
        private let bytesPerSecond: Int
        private let lock = NSLock()
        private var sockets: [Int32] = []
        private var closed = false

        /// - Parameters:
        ///   - locator: the router, as `tcp/<host>:<port>`.
        ///   - bytesPerSecond: the router-to-client rate.
        init(upstream locator: String, bytesPerSecond: Int) throws {
            guard locator.hasPrefix("tcp/"), let colon = locator.lastIndex(of: ":") else {
                throw ProxyError.unsupportedLocator(locator)
            }
            var host = String(locator[locator.index(locator.startIndex, offsetBy: 4)..<colon])
            if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
            upstreamHost = host
            upstreamPort = String(locator[locator.index(after: colon)...])
            self.bytesPerSecond = bytesPerSecond

            let fd = try Self.makeSocket(host: "127.0.0.1", port: "0", listening: true)
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0, listen(fd, 8) == 0 else {
                _ = systemClose(fd)
                throw ProxyError.system("listen", errno)
            }
            listener = fd
            port = UInt16(bigEndian: address.sin_port)

            Thread.detachNewThread { [self] in acceptLoop() }
        }

        /// Stops accepting and cuts every proxied connection.
        func close() {
            lock.lock()
            closed = true
            let open = sockets
            sockets = []
            lock.unlock()
            _ = shutdown(listener, Int32(SHUT_RDWR))
            _ = systemClose(listener)
            for fd in open {
                _ = shutdown(fd, Int32(SHUT_RDWR))
            }
        }

        private func acceptLoop() {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                guard let upstream = try? Self.makeSocket(host: upstreamHost, port: upstreamPort, listening: false),
                    track(client, upstream)
                else {
                    _ = systemClose(client)
                    continue
                }
                Thread.detachNewThread { [self] in pump(from: client, to: upstream, bytesPerSecond: 0) }
                Thread.detachNewThread { [self] in pump(from: upstream, to: client, bytesPerSecond: bytesPerSecond) }
            }
        }

        private func track(_ fds: Int32...) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if closed { return false }
            sockets.append(contentsOf: fds)
            return true
        }

        private func pump(from source: Int32, to destination: Int32, bytesPerSecond: Int) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let start = DispatchTime.now().uptimeNanoseconds
            var forwarded = 0
            loop: while true {
                let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
                guard count > 0 else { break }
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes {
                        send(destination, $0.baseAddress! + offset, count - offset, Self.sendFlags)
                    }
                    guard written > 0 else { break loop }
                    offset += written
                }
                forwarded += count
                if bytesPerSecond > 0 {
                    let due = UInt64(Double(forwarded) / Double(bytesPerSecond) * 1e9)
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    if due > elapsed { usleep(useconds_t((due - elapsed) / 1000)) }
                }
            }
            _ = shutdown(source, Int32(SHUT_RDWR))
            _ = shutdown(destination, Int32(SHUT_RDWR))
        }

        private static func makeSocket(host: String, port: String, listening: Bool) throws -> Int32 {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = streamType
            hints.ai_flags = listening ? AI_PASSIVE : 0
            var info: UnsafeMutablePointer<addrinfo>?
            let resolved = getaddrinfo(host, port, &hints, &info)
            guard resolved == 0, let first = info else { throw ProxyError.resolve(host, resolved) }
            defer { freeaddrinfo(info) }
            var entry: UnsafeMutablePointer<addrinfo>? = first
            while let current = entry {
                let fd = socket(current.pointee.ai_family, current.pointee.ai_socktype, 0)
                if fd >= 0 {
                    var one: Int32 = 1
                    #if canImport(Darwin)
                        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    #endif
                    let done: Int32
                    if listening {
                        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                        done = bind(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
                    } else {
                        done = connect(fd, current.pointee.ai_addr, current.pointee.ai_addrlen)
                    }
                    if done == 0 { return fd }
                    _ = systemClose(fd)
                }
                entry = current.pointee.ai_next
            }
            throw ProxyError.system(listening ? "bind" : "connect", errno)
        }

        #if canImport(Glibc)
            private static let streamType = Int32(SOCK_STREAM.rawValue)
            private static let sendFlags = Int32(MSG_NOSIGNAL)
        #else
            private static let streamType = SOCK_STREAM
            private static let sendFlags: Int32 = 0
        #endif

        enum ProxyError: Error {
            case unsupportedLocator(String)
            case resolve(String, Int32)
            case system(String, Int32)
        }
    }

    // `close` is shadowed by the proxy's own `close()`.
    private func systemClose(_ fd: Int32) -> Int32 {
        close(fd)
    }

#endif
