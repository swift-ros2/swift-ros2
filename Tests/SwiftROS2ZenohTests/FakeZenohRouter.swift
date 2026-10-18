import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if canImport(Darwin) || canImport(Glibc)

    /// A TCP listener that answers one zenoh-pico client's handshake like a
    /// router and then sends the batches a test hands it, byte for byte. It
    /// lets a test put transport messages side by side in one batch the way
    /// zenohd does, without depending on when zenohd decides to batch.
    ///
    /// Only what zenoh-pico's client handshake checks is implemented: InitAck
    /// echoes the sequence-number resolution and batch size of the InitSyn
    /// (zenoh-pico rejects larger values) and announces no QoS, and OpenAck
    /// gives a 10 s lease and an initial sequence number of 0 on both channels.
    /// Everything the client sends after the handshake is read and discarded.
    final class FakeZenohRouter: @unchecked Sendable {
        let port: UInt16
        var locator: String { "tcp/127.0.0.1:\(port)" }

        private let listener: Int32
        private let lock = NSLock()
        private let opened = DispatchSemaphore(value: 0)
        private var connection: Int32 = -1
        private var closed = false
        private var failure: String?

        init() throws {
            let fd = socket(AF_INET, Self.streamType, 0)
            guard fd >= 0 else { throw RouterError.system("socket", errno) }
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            #if canImport(Darwin)
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            #endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
                }
            }
            guard bound, listen(fd, 1) == 0 else {
                let code = errno
                _ = closeDescriptor(fd)
                throw RouterError.system("listen", code)
            }
            listener = fd
            port = UInt16(bigEndian: address.sin_port)

            Thread.detachNewThread { [self] in serve() }
        }

        /// Waits until a client has completed the handshake. Throws with what
        /// went wrong if it did not.
        func waitForSession(timeout: TimeInterval = 10) throws {
            if opened.wait(timeout: .now() + timeout) == .timedOut {
                throw RouterError.handshake("no client completed the handshake")
            }
            lock.lock()
            defer { lock.unlock() }
            if let failure { throw RouterError.handshake(failure) }
        }

        /// Sends `batch` as one TCP batch: its 16-bit little-endian length,
        /// then its bytes.
        func send(batch: [UInt8]) throws {
            precondition(batch.count <= Int(UInt16.max))
            lock.lock()
            let fd = connection
            lock.unlock()
            guard fd >= 0 else { throw RouterError.handshake("no session") }
            let bytes = [UInt8(batch.count & 0xff), UInt8(batch.count >> 8)] + batch
            try Self.writeAll(fd, bytes)
        }

        /// Stops listening and cuts the session.
        func close() {
            lock.lock()
            closed = true
            let fd = connection
            lock.unlock()
            _ = shutdown(listener, Int32(SHUT_RDWR))
            _ = closeDescriptor(listener)
            if fd >= 0 { _ = shutdown(fd, Int32(SHUT_RDWR)) }
        }

        private func serve() {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else {
                fail("accept failed: \(errno)")
                return
            }
            #if canImport(Darwin)
                var one: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            lock.lock()
            if closed {
                lock.unlock()
                _ = closeDescriptor(fd)
                return
            }
            connection = fd
            lock.unlock()

            do {
                try handshake(fd)
            } catch {
                fail("\(error)")
                return
            }
            opened.signal()
            // Drain the client's declarations and keep-alives. Hang up on its
            // CLOSE, as a router does, so the client's read task ends at once.
            while let batch = try? Self.readBatch(fd), batch.first.map({ $0 & 0x1f }) != Self.midClose {}
            _ = shutdown(fd, Int32(SHUT_RDWR))
            _ = closeDescriptor(fd)
        }

        private func handshake(_ fd: Int32) throws {
            // InitSyn: header, version, whatami and zid length, zid, then (S flag)
            // the resolution byte and the batch size.
            let initSyn = try Self.readBatch(fd)
            guard initSyn.count >= 3, initSyn[0] & 0x1f == Self.midInit, initSyn[0] & Self.flagA == 0 else {
                throw RouterError.handshake("expected InitSyn, got \(initSyn.prefix(4))")
            }
            var resolution: UInt8 = 0x0a
            var batchSize: [UInt8] = [0x00, 0x08]  // 2048
            if initSyn[0] & Self.flagS != 0 {
                let offset = 3 + Int(initSyn[2] >> 4) + 1
                guard initSyn.count >= offset + 3 else { throw RouterError.handshake("short InitSyn") }
                resolution = initSyn[offset]
                batchSize = Array(initSyn[(offset + 1)...(offset + 2)])
            }
            var initAck: [UInt8] = [Self.midInit | Self.flagA | Self.flagS, Self.protocolVersion]
            initAck.append(0xf0)  // a 16-byte zid, whatami router
            initAck += (1...16).map { UInt8($0) }
            initAck.append(resolution)
            initAck += batchSize
            initAck += [0x01, 0x2a]  // a one-byte cookie
            try Self.writeAll(fd, Self.lengthPrefixed(initAck))

            let openSyn = try Self.readBatch(fd)
            guard let header = openSyn.first, header & 0x1f == Self.midOpen, header & Self.flagA == 0 else {
                throw RouterError.handshake("expected OpenSyn, got \(openSyn.prefix(4))")
            }
            // OpenAck: lease in seconds (T flag), initial sequence number.
            let openAck: [UInt8] = [Self.midOpen | Self.flagA | 0x40, 10, 0]
            try Self.writeAll(fd, Self.lengthPrefixed(openAck))
        }

        private func fail(_ message: String) {
            lock.lock()
            failure = message
            lock.unlock()
            opened.signal()
        }

        // MARK: - Messages

        /// A FRAME header. The network messages of the frame follow it in the batch.
        static func frame(reliable: Bool, sn: UInt64) -> [UInt8] {
            [midFrame | (reliable ? 0x20 : 0)] + zint(sn)
        }

        /// A PUSH of a PUT with `payload` to `key`, the key sent as a suffix with
        /// no declared resource.
        static func push(key: String, payload: [UInt8]) -> [UInt8] {
            let keyBytes = Array(key.utf8)
            var message: [UInt8] = [midPush | 0x20, 0x00]
            message += zint(UInt64(keyBytes.count)) + keyBytes
            message.append(midPut)
            message += zint(UInt64(payload.count)) + payload
            return message
        }

        static func zint(_ value: UInt64) -> [UInt8] {
            var value = value
            var bytes: [UInt8] = []
            repeat {
                var byte = UInt8(value & 0x7f)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }

        private static let protocolVersion: UInt8 = 0x09
        private static let midInit: UInt8 = 0x01
        private static let midOpen: UInt8 = 0x02
        private static let midClose: UInt8 = 0x03
        private static let midFrame: UInt8 = 0x05
        private static let midPush: UInt8 = 0x1d
        private static let midPut: UInt8 = 0x01
        private static let flagA: UInt8 = 0x20
        private static let flagS: UInt8 = 0x40

        // MARK: - Socket I/O

        private static func lengthPrefixed(_ batch: [UInt8]) -> [UInt8] {
            [UInt8(batch.count & 0xff), UInt8(batch.count >> 8)] + batch
        }

        private static func readBatch(_ fd: Int32) throws -> [UInt8] {
            let header = try readExactly(fd, 2)
            return try readExactly(fd, Int(header[0]) | Int(header[1]) << 8)
        }

        private static func readExactly(_ fd: Int32, _ count: Int) throws -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            var offset = 0
            while offset < count {
                let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
                guard got > 0 else { throw RouterError.system("read", errno) }
                offset += got
            }
            return buffer
        }

        private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws {
            var offset = 0
            while offset < bytes.count {
                let written = bytes.withUnsafeBytes {
                    Glue.send(fd, $0.baseAddress! + offset, bytes.count - offset, sendFlags)
                }
                guard written > 0 else { throw RouterError.system("send", errno) }
                offset += written
            }
        }

        #if canImport(Glibc)
            private static let streamType = Int32(SOCK_STREAM.rawValue)
            private static let sendFlags = Int32(MSG_NOSIGNAL)
        #else
            private static let streamType = SOCK_STREAM
            private static let sendFlags: Int32 = 0
        #endif

        enum RouterError: Error {
            case system(String, Int32)
            case handshake(String)
        }
    }

    /// The C functions that the router's own `send(batch:)` and `close()` shadow.
    private enum Glue {
        static func send(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int, _ flags: Int32) -> Int {
            #if canImport(Glibc)
                return Glibc.send(fd, buffer, count, flags)
            #else
                return Darwin.send(fd, buffer, count, flags)
            #endif
        }
    }

    private func closeDescriptor(_ fd: Int32) -> Int32 {
        close(fd)
    }

#endif
