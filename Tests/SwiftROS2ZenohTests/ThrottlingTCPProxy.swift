import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)

    /// A TCP proxy in front of a Zenoh router that limits the router-to-client
    /// direction to a byte rate, like a slow Wi-Fi link. The router's queue
    /// toward a session behind it fills up, so the router drops droppable
    /// messages (best effort or `CongestionControl::Drop`) the way it does for a
    /// slow device. The rate is an average over the life of a connection: time
    /// in which less was sent is not lost, so traffic after a quiet stretch
    /// passes at full speed. The client-to-router direction is not throttled.
    ///
    /// The proxy also reads what it forwards to the client, so that a test can
    /// tell a message the router did not send from one the client lost: see
    /// `fragmentedMessages`.
    final class ThrottlingTCPProxy: @unchecked Sendable {
        /// A message the router sent toward a client in fragments.
        struct FragmentedMessage: Equatable {
            /// The fragment payload bytes that were forwarded: the message with
            /// its network header of a few dozen bytes.
            let bytes: Int
            /// `false` when the router stopped before the last fragment, which is
            /// how it drops a message it has started to send, and for a message
            /// it is still sending.
            let complete: Bool
        }

        let port: UInt16
        var locator: String { "tcp/127.0.0.1:\(port)" }

        /// The fragmented messages forwarded to the clients so far: the ones that
        /// ended, in that order, then the ones in progress. A message the router
        /// dropped before its first fragment is not among them.
        var fragmentedMessages: [FragmentedMessage] {
            lock.lock()
            defer { lock.unlock() }
            return ended + inProgress.values.map { FragmentedMessage(bytes: $0, complete: false) }
        }

        private let listener: Int32
        private let upstreamHost: String
        private let upstreamPort: String
        private let bytesPerSecond: Int
        private let lock = NSLock()
        private var sockets: [Int32] = []
        private var closed = false
        private var ended: [FragmentedMessage] = []
        /// Bytes of the message in progress, by the socket it comes from.
        private var inProgress: [Int32: Int] = [:]

        /// - Parameters:
        ///   - locator: the router, as `tcp/<host>:<port>`.
        ///   - bytesPerSecond: the most the router may have sent to a client, per
        ///     second since that client connected.
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
            // Only the throttled direction comes from the router.
            var meter = bytesPerSecond > 0 ? FragmentMeter() : nil
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
                if let progress = meter?.consume(buffer[0..<count]) {
                    lock.lock()
                    ended.append(contentsOf: progress.ended)
                    inProgress[source] = progress.openBytes
                    lock.unlock()
                }
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

        /// Follows the FRAGMENT messages of a router-to-client Zenoh stream. The
        /// stream is a sequence of batches, each behind a 2-byte little-endian
        /// length. A batch that starts with a FRAGMENT holds nothing else: the
        /// fragment's payload runs to the end of the batch. The router marks the
        /// first fragment of a message and clears the "more" flag on the last
        /// one; when it drops a message half way it just starts the next one.
        /// The meter follows one message at a time, which is enough while
        /// everything the router fragments has the same priority.
        private struct FragmentMeter {
            private var pending: [UInt8] = []
            private var open: (bytes: Int, lastSequenceNumber: UInt64)?

            /// Takes the next bytes of the stream. Returns the messages that ended
            /// in them and the size of the one in progress, if any.
            mutating func consume(_ chunk: ArraySlice<UInt8>) -> (ended: [FragmentedMessage], openBytes: Int?) {
                pending.append(contentsOf: chunk)
                var ended: [FragmentedMessage] = []
                var offset = 0
                while pending.count - offset >= 2 {
                    let length = Int(pending[offset]) | Int(pending[offset + 1]) << 8
                    guard pending.count - offset >= 2 + length else { break }
                    follow(pending[(offset + 2)..<(offset + 2 + length)], ended: &ended)
                    offset += 2 + length
                }
                pending.removeFirst(offset)
                return (ended, open?.bytes)
            }

            private mutating func follow(_ batch: ArraySlice<UInt8>, ended: inout [FragmentedMessage]) {
                var index = batch.startIndex
                guard index < batch.endIndex else { return }
                let header = batch[index]
                index += 1
                guard header & 0x1F == 0x06 else { return }  // not a FRAGMENT
                guard let sequenceNumber = Self.integer(in: batch, at: &index) else { return }
                var isFirst = false
                var isDropped = false
                var hasExtension = header & 0x80 != 0
                while hasExtension {
                    guard index < batch.endIndex else { return }
                    let ext = batch[index]
                    index += 1
                    hasExtension = ext & 0x80 != 0
                    switch (ext >> 5) & 0x03 {
                    case 0:  // no body: "first" is 2, "drop" is 3
                        isFirst = isFirst || ext & 0x0F == 0x02
                        isDropped = isDropped || ext & 0x0F == 0x03
                    case 1:  // an integer (the priority)
                        guard Self.integer(in: batch, at: &index) != nil else { return }
                    case 2:  // a buffer
                        guard let size = Self.integer(in: batch, at: &index), size <= UInt64(batch.endIndex - index)
                        else { return }
                        index += Int(size)
                    default:
                        return
                    }
                }
                // Sequence numbers wrap to 0 at a resolution the meter does not know.
                let follows = { (last: UInt64) in sequenceNumber == last &+ 1 || sequenceNumber == 0 }
                if let current = open, isFirst || !follows(current.lastSequenceNumber) {
                    ended.append(FragmentedMessage(bytes: current.bytes, complete: false))
                    open = nil
                }
                let bytes = (open?.bytes ?? 0) + (batch.endIndex - index)
                let hasMore = header & 0x40 != 0
                if isDropped || !hasMore {
                    ended.append(FragmentedMessage(bytes: bytes, complete: !isDropped))
                    open = nil
                } else {
                    open = (bytes, sequenceNumber)
                }
            }

            /// Zenoh's variable-length integer: 7 bits a byte, low bits first, the
            /// high bit set on every byte but the last.
            private static func integer(in batch: ArraySlice<UInt8>, at index: inout Int) -> UInt64? {
                var value: UInt64 = 0
                var shift: UInt64 = 0
                while index < batch.endIndex, shift < 64 {
                    let byte = batch[index]
                    index += 1
                    value |= UInt64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return value }
                    shift += 7
                }
                return nil
            }
        }

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
