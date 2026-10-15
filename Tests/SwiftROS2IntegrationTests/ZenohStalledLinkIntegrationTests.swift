import Foundation
import SwiftROS2
import SwiftROS2TestFixtures
import SwiftROS2Transport
import XCTest

#if canImport(Darwin)
    import Darwin
#endif

/// Reliable publishers block on congestion, so they wait for the send in
/// progress on the session. When the network stalls, that send must still end:
/// the publishes waiting behind it have to fail within a bounded time (and the
/// session report itself lost) instead of hanging their callers forever.
///
/// The test reaches the router through an in-process TCP relay that it then
/// stalls: the relay stops reading from both sides but keeps both connections
/// open, so the session's peer advertises a zero window, as a peer that stopped
/// reading or a path that stopped delivering would. Requires `ZENOH_ROUTER`
/// (`tcp/<host>:<port>`, for example `tcp/192.168.1.85:7447`). Skips
/// otherwise, and on platforms without Darwin sockets.
final class ZenohStalledLinkIntegrationTests: XCTestCase {
    func testStalledLinkFailsBlockedReliablePublishesInBoundedTime() async throws {
        #if canImport(Darwin)
            guard let router = ProcessInfo.processInfo.environment["ZENOH_ROUTER"], !router.isEmpty else {
                throw XCTSkip("Set ZENOH_ROUTER to run this test (for example tcp/192.168.1.85:7447)")
            }
            let relay = try StallingRelay(upstream: router)
            defer { relay.close() }

            let ctx = try await ROS2Context(
                transport: .zenoh(locator: "tcp/127.0.0.1:\(relay.port)", domainId: 0), distro: .jazzy)
            let node = try await ctx.createNode(name: "stalled_link_it", namespace: "/zenoh_stalled_link_it")
            let threads = 4
            var publishers: [ROS2Publisher<Imu>] = []
            for t in 0..<threads {
                publishers.append(try await node.createPublisher(Imu.self, topic: "imu_\(t)", qos: .reliableSensor))
            }
            let message = Imu(header: Header(frameId: "imu_link"))
            for p in publishers { try p.publish(message) }

            relay.stall()
            let stalledAt = Date()

            // Publish at 100 Hz on every publisher until a publish fails. Before
            // sends were bounded, the publish stuck in the stalled send and all
            // the publishes waiting for it never returned.
            let firstFailure = FirstFailures(count: threads)
            let done = DispatchGroup()
            for t in 0..<threads {
                done.enter()
                Thread.detachNewThread {
                    defer { done.leave() }
                    while Date().timeIntervalSince(stalledAt) < 60 {
                        do {
                            try publishers[t].publish(message)
                        } catch {
                            firstFailure.record(t, after: Date().timeIntervalSince(stalledAt))
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
            let finished = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                DispatchQueue.global().async { cont.resume(returning: done.wait(timeout: .now() + 45) == .success) }
            }
            print("[ZenohStalledLink] first failure per publisher after the stall (s): \(firstFailure.values)")
            guard finished else {
                // Leave the context open: closing it would block as well.
                XCTFail("publishes still blocked 45 s after the stall: \(firstFailure.values)")
                return
            }
            // Publishes keep succeeding until the socket's send buffer is full,
            // then the blocked send fails after the bridge's 5 s send timeout.
            let worst = firstFailure.values.compactMap { $0 }.max() ?? .infinity
            XCTAssertLessThan(worst, 30, "\(firstFailure.values)")

            // The failed blocking send takes the link down, so the session
            // reports the transport lost soon after, and publishes fail at once.
            let lostDeadline = Date().addingTimeInterval(10)
            var lastError: Error?
            while Date() < lostDeadline {
                do {
                    try publishers[0].publish(message)
                } catch {
                    lastError = error
                    if case .sessionUnhealthy = error as? TransportError { break }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard case .sessionUnhealthy = lastError as? TransportError else {
                XCTFail("session not reported lost: \(String(describing: lastError))")
                await ctx.shutdown()
                return
            }
            let started = Date()
            XCTAssertThrowsError(try publishers[1].publish(message))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)

            await ctx.shutdown()
        #else
            throw XCTSkip("Needs Darwin sockets for the stalling relay")
        #endif
    }
}

/// The first failure time of each publishing thread.
private final class FirstFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval?]

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func record(_ index: Int, after seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if storage[index] == nil { storage[index] = seconds }
    }

    var values: [TimeInterval?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

#if canImport(Darwin)
    /// A TCP relay from 127.0.0.1 to a `tcp/<host>:<port>` locator that can be
    /// stalled: once stalled it stops reading from both sides and keeps both
    /// connections open. Its sockets have small receive buffers, so the peer's
    /// window closes after a few kilobytes.
    private final class StallingRelay: @unchecked Sendable {
        let port: UInt16
        private let listener: Int32
        private let upstreamHost: String
        private let upstreamPort: String
        private let lock = NSLock()
        private var stalled = false
        private var closed = false
        private var sockets: [Int32] = []
        private var pendingUpstream: Int32?

        init(upstream locator: String) throws {
            let address = locator.hasPrefix("tcp/") ? String(locator.dropFirst(4)) : locator
            guard let colon = address.lastIndex(of: ":") else { throw RelayError.badLocator(locator) }
            upstreamHost = String(address[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            upstreamPort = String(address[address.index(after: colon)...])

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw RelayError.socket(errno) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            Self.shrinkReceiveBuffer(fd)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(fd, 4) == 0 else {
                Darwin.close(fd)
                throw RelayError.socket(errno)
            }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            listener = fd
            port = UInt16(bigEndian: addr.sin_port)
            // Connect upstream before the session does: zenoh-pico reads the
            // handshake reply with a short timeout.
            pendingUpstream = connectUpstream()
            Thread.detachNewThread { [self] in acceptLoop() }
        }

        func stall() {
            lock.lock()
            stalled = true
            lock.unlock()
        }

        func close() {
            lock.lock()
            closed = true
            let all = sockets + [listener] + (pendingUpstream.map { [$0] } ?? [])
            pendingUpstream = nil
            lock.unlock()
            for fd in all {
                shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
        }

        private var isStalled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stalled
        }

        private var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }

        private func acceptLoop() {
            while !isClosed {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Self.shrinkReceiveBuffer(client)
                lock.lock()
                let ready = pendingUpstream
                pendingUpstream = nil
                lock.unlock()
                guard let upstream = ready ?? connectUpstream() else {
                    Darwin.close(client)
                    continue
                }
                lock.lock()
                sockets += [client, upstream]
                lock.unlock()
                Thread.detachNewThread { [self] in pump(from: client, to: upstream) }
                Thread.detachNewThread { [self] in pump(from: upstream, to: client) }
            }
        }

        private func connectUpstream() -> Int32? {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(upstreamHost, upstreamPort, &hints, &info) == 0, let first = info else { return nil }
            defer { freeaddrinfo(info) }
            let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
            guard fd >= 0 else { return nil }
            Self.shrinkReceiveBuffer(fd)
            guard connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else {
                Darwin.close(fd)
                return nil
            }
            return fd
        }

        private func pump(from source: Int32, to destination: Int32) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !isClosed {
                if isStalled {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                let n = buffer.withUnsafeMutableBytes { recv(source, $0.baseAddress, $0.count, 0) }
                guard n > 0 else { return }
                var sent = 0
                while sent < n {
                    let m = buffer.withUnsafeBytes { send(destination, $0.baseAddress! + sent, n - sent, 0) }
                    guard m > 0 else { return }
                    sent += m
                }
            }
        }

        private static func shrinkReceiveBuffer(_ fd: Int32) {
            var size: Int32 = 16 * 1024
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        }

        enum RelayError: Error {
            case badLocator(String)
            case socket(Int32)
        }
    }
#endif
