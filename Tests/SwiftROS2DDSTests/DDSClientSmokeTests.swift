import SwiftROS2TestSupport
import XCTest

@testable import SwiftROS2DDS

final class DDSClientSmokeTests: XCTestCase {
    func testWriteWithForeignHandleThrows() throws {
        let client = DDSClient()
        let foreign = ForeignWriterHandle()
        XCTAssertThrowsError(
            try client.writeRawCDR(
                writer: foreign, data: Data([0x00, 0x01, 0x00, 0x00]), timestamp: 0)
        ) { error in
            guard let e = error as? DDSError else {
                XCTFail("Expected DDSError, got \(type(of: error))")
                return
            }
            if case .writeFailed = e {
                // ok
            } else {
                XCTFail("Expected .writeFailed, got \(e)")
            }
        }
    }

    func testDestroyReaderWithForeignHandleIsNoOp() {
        let client = DDSClient()
        let foreign = ForeignReaderHandle()
        // destroyReader is non-throwing; the client must silently no-op on a
        // handle it didn't create rather than force-cast into its private box.
        client.destroyReader(foreign)
    }

    func testCreateReaderWithoutSessionThrows() throws {
        let client = DDSClient()
        XCTAssertThrowsError(
            try client.createRawReader(
                topicName: "rt/test",
                typeName: "std_msgs::msg::dds_::String_",
                qos: DDSBridgeQoSConfig(),
                userData: nil,
                handler: { _, _ in }
            )
        ) { error in
            guard let e = error as? DDSError else {
                XCTFail("Expected DDSError, got \(type(of: error))")
                return
            }
            if case .notConnected = e {
                // ok
            } else {
                XCTFail("Expected .notConnected, got \(e)")
            }
        }
    }

    /// `isPublicationMatched` / `isSubscriptionMatched` follow CycloneDDS's
    /// matched status: a service client's `waitForService` relies on them.
    func testMatchedStatusFollowsLocalEndpoints() async throws {
        let client = DDSClient()
        // A domain at or below 101 keeps its fixed UDP ports (7400 + 250 × id)
        // out of the ephemeral range, where Windows reserves blocks no socket can bind.
        try client.createSession(domainId: 77, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        defer { try? client.destroySession() }

        let topic = "rt/swift_ros2_matched_status_test"
        let type = "std_msgs::msg::dds_::String_"
        let writer = try client.createRawWriter(
            topicName: topic, typeName: type, qos: DDSBridgeQoSConfig(), userData: nil)
        XCTAssertFalse(client.isPublicationMatched(writer: writer))

        let reader = try client.createRawReader(
            topicName: topic, typeName: type, qos: DDSBridgeQoSConfig(), userData: nil, handler: { _, _ in })
        await waitUntil {
            client.isPublicationMatched(writer: writer) && client.isSubscriptionMatched(reader: reader)
        }

        client.destroyWriter(writer)
        XCTAssertFalse(client.isPublicationMatched(writer: writer), "a closed writer reports unmatched")
        await waitUntil { !client.isSubscriptionMatched(reader: reader) }

        client.destroyReader(reader)
        XCTAssertFalse(client.isSubscriptionMatched(reader: reader), "a closed reader reports unmatched")
        XCTAssertFalse(client.isSubscriptionMatched(reader: ForeignReaderHandle()))
    }

    /// A transient-local reader created after a local writer published gets the cached
    /// sample while it is being created, exactly once.
    func testLateTransientLocalReaderGetsTheCachedSampleOnce() async throws {
        let client = DDSClient()
        // Domain 80: used only by the DDSClient tests, at or below 101 like 77 above.
        try client.createSession(domainId: 80, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        defer { try? client.destroySession() }
        let topic = "rt/swift_ros2_replay_test"
        let type = "std_msgs::msg::dds_::String_"
        let qos = DDSBridgeQoSConfig(reliability: .reliable, durability: .transientLocal, historyDepth: 1)
        let writer = try client.createRawWriter(topicName: topic, typeName: type, qos: qos, userData: nil)
        defer { client.destroyWriter(writer) }
        let sample = Data([0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x68, 0x69, 0x00, 0x00])
        try client.writeRawCDR(writer: writer, data: sample, timestamp: 1)

        let received = ReceivedSamples()
        let reader = try client.createRawReader(
            topicName: topic, typeName: type, qos: qos, userData: nil, handler: { data, _ in received.append(data) })
        defer { client.destroyReader(reader) }

        XCTAssertEqual(received.all, [sample], "delivered while the reader was created")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(received.all, [sample], "and not again")
    }

    /// The handler of a late transient-local reader gets the cached sample on the creating
    /// thread, after the client lock is released, so it can call back into the client.
    func testLateReaderHandlerCanCallTheClient() throws {
        let client = DDSClient()
        try client.createSession(domainId: 80, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        let topic = "rt/swift_ros2_replay_reentrant_create"
        let writer = try client.createRawWriter(
            topicName: topic, typeName: Self.stringType, qos: Self.latched, userData: nil)
        try client.writeRawCDR(writer: writer, data: Self.sample("hi"), timestamp: 1)

        let created = HandleBox()
        let finished = runDetached {
            let reader = try? client.createRawReader(
                topicName: topic, typeName: Self.stringType, qos: Self.latched, userData: nil,
                handler: { _, _ in
                    created.set(
                        try? client.createRawReader(
                            topicName: "rt/swift_ros2_replay_reentrant_other", typeName: Self.stringType,
                            qos: DDSBridgeQoSConfig(), userData: nil, handler: { _, _ in }))
                })
            if let reader { client.destroyReader(reader) }
        }
        guard finished else {
            // The creating thread is stuck on the client lock: leave the session alone.
            return XCTFail("a handler that calls the client deadlocked createRawReader")
        }
        let other = try XCTUnwrap(created.get(), "the handler created a second reader")
        client.destroyReader(other)
        client.destroyWriter(writer)
        try client.destroySession()
    }

    /// A latched reader's handler that publishes to its own topic gets its own sample too:
    /// the write is delivered to the reader on the same thread while the reader drains.
    func testLateReaderHandlerThatPublishesToItsOwnTopicGetsBothSamples() async throws {
        let client = DDSClient()
        try client.createSession(domainId: 80, discoveryConfig: DDSBridgeDiscoveryConfig(mode: .multicast))
        let topic = "rt/swift_ros2_replay_reentrant_write"
        let writer = try client.createRawWriter(
            topicName: topic, typeName: Self.stringType, qos: Self.latched, userData: nil)
        let first = Self.sample("hi")
        let second = Self.sample("yo")
        try client.writeRawCDR(writer: writer, data: first, timestamp: 1)

        let received = ReceivedSamples()
        let created = HandleBox()
        let finished = runDetached {
            created.set(
                try? client.createRawReader(
                    topicName: topic, typeName: Self.stringType, qos: Self.latched, userData: nil,
                    handler: { data, _ in
                        received.append(data)
                        if data == first {
                            try? client.writeRawCDR(writer: writer, data: second, timestamp: 2)
                        }
                    }))
        }
        guard finished else {
            return XCTFail("a handler that writes to its own topic deadlocked createRawReader")
        }
        let reader = try XCTUnwrap(created.get())
        await waitUntil("both samples arrive", interval: .milliseconds(20)) { received.all.count >= 2 }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(received.all, [first, second])

        client.destroyReader(reader)
        client.destroyWriter(writer)
        try client.destroySession()
    }

    private static let stringType = "std_msgs::msg::dds_::String_"
    private static let latched = DDSBridgeQoSConfig(
        reliability: .reliable, durability: .transientLocal, historyDepth: 1)

    /// A `std_msgs/String` sample of a two-letter string.
    private static func sample(_ text: String) -> Data {
        Data([0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00]) + Data(text.utf8) + Data([0x00, 0x00])
    }

    /// Runs `body` on its own thread and waits up to five seconds for it. Returns
    /// whether it finished; a deadlocked thread is left behind.
    private func runDetached(_ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread {
            body()
            done.signal()
        }.start()
        return done.wait(timeout: .now() + 5) == .success
    }
}

private final class HandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: (any DDSReaderHandle)?

    func set(_ handle: (any DDSReaderHandle)?) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }

    func get() -> (any DDSReaderHandle)? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }
}

private final class ForeignWriterHandle: DDSWriterHandle {
    var isActive: Bool { false }
    func close() {}
}

private final class ForeignReaderHandle: DDSReaderHandle {
    var isActive: Bool { false }
    func close() {}
}

private final class ReceivedSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        samples.append(data)
        lock.unlock()
    }

    var all: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
