// Publisher.swift
// ROS 2 Publisher

import Foundation
import SwiftROS2CDR
import SwiftROS2Messages
import SwiftROS2Transport

/// ROS 2 publisher for a specific message type
///
/// ```swift
/// let pub = try await node.createPublisher(Imu.self, topic: "imu")
/// try pub.publish(imuMessage)
/// ```
public final class ROS2Publisher<M: CDREncodable & ROS2MessageType>: @unchecked Sendable, NodeEntity {
    private let transportPublisher: any TransportPublisher
    private let isLegacySchema: Bool
    private var sequenceNumber: Int64 = 0
    private let lock = NSLock()
    private let matchedMonitor: MatchedSubscriptionsMonitor

    init(transportPublisher: any TransportPublisher, isLegacySchema: Bool = false) {
        self.transportPublisher = transportPublisher
        self.isLegacySchema = isLegacySchema
        self.matchedMonitor = MatchedSubscriptionsMonitor { [transportPublisher] in
            transportPublisher.matchedSubscriptions ?? true
        }
    }

    /// Publish a message
    ///
    /// The Publisher writes the 4-byte CDR encapsulation header (`00 01 00 00` for
    /// little-endian XCDR v1) before delegating to `message.encode(to:)`. All
    /// `ROS2Message` conformers (generated and hand-written) write payload only —
    /// the Publisher writes the header. Per-type `encode(to:)` implementations
    /// must therefore not call `writeEncapsulationHeader()` themselves.
    ///
    /// The attachment's `timestamp_ns` field carries the wall-clock publish time
    /// and the sequence number comes from this publisher's own monotonic counter.
    /// Use ``publish(_:timestamp:sequenceNumber:)`` to supply a source timestamp
    /// (e.g. a sensor capture time) and/or an explicit sequence number instead.
    public func publish(_ message: M) throws {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        try publish(message, timestamp: timestamp, sequenceNumber: nil)
    }

    /// Publish a message with a caller-supplied source timestamp.
    ///
    /// Identical to ``publish(_:)`` in how it serializes the message (4-byte CDR
    /// encapsulation header + `message.encode(to:)`), but the attachment's
    /// `timestamp_ns` field carries `timestamp` instead of the wall-clock publish
    /// time. This lets a publisher stamp the message with the moment the data was
    /// captured (e.g. a sensor sample time) rather than the moment it went on the
    /// wire.
    ///
    /// - Parameters:
    ///   - message: The typed message to publish.
    ///   - timestamp: Source timestamp in nanoseconds since the Unix epoch,
    ///     written verbatim into the attachment's `timestamp_ns` field.
    ///   - sequenceNumber: An explicit attachment sequence number. When `nil`
    ///     (the default) this publisher's own monotonic counter is used, exactly
    ///     as ``publish(_:)`` does.
    public func publish(_ message: M, timestamp: UInt64, sequenceNumber: Int64? = nil) throws {
        let encoder = CDREncoder(isLegacySchema: isLegacySchema)
        encoder.writeEncapsulationHeader()
        try message.encode(to: encoder)
        let data = encoder.getData()

        let seq: Int64
        if let sequenceNumber {
            seq = sequenceNumber
        } else {
            lock.lock()
            seq = self.sequenceNumber
            self.sequenceNumber += 1
            lock.unlock()
        }

        try transportPublisher.publish(data: data, timestamp: timestamp, sequenceNumber: seq)
    }

    /// The topic this publisher is associated with
    public var topic: String {
        transportPublisher.topic
    }

    /// Whether the publisher is active
    public var isActive: Bool {
        transportPublisher.isActive
    }

    /// Whether at least one subscription currently matches this publisher.
    ///
    /// Fail-open: a transport that cannot tell reports `true`, so callers that
    /// skip work without subscribers keep publishing. On wire Zenoh that
    /// includes a session that has lost its router: the state is unknown, so
    /// this reports `true` instead of the last state seen before the loss, and
    /// the next ``publish(_:)`` throws, which lets a caller that only publishes
    /// with subscribers notice the loss and reconnect.
    public var hasMatchedSubscriptions: Bool {
        transportPublisher.matchedSubscriptions ?? true
    }

    /// Calls `handler` once with ``hasMatchedSubscriptions`` before returning,
    /// then on every change until the publisher is closed.
    ///
    /// The state is sampled every 50 ms. `handler` always runs on one private
    /// serial queue, the initial call included, and that call completes before
    /// this method returns. Registering a new handler replaces the previous one.
    ///
    /// No call happens once the publisher is closed: closing it (through
    /// `ROS2Node.destroy()` or `ROS2Context.shutdown()`) waits for a call that
    /// is already running. That wait happens on the context's teardown queue,
    /// not on the cooperative thread pool. `handler` must therefore not block
    /// on a lock held by the code that closes the publisher, nor wait for any
    /// other teardown of the same context (`ROS2Node.destroy()`,
    /// `ROS2Context.shutdown()`, `ROS2ParameterClient.close()`), which only
    /// starts once this close has finished.
    public func onMatchedSubscriptionsChanged(_ handler: @escaping @Sendable (Bool) -> Void) {
        matchedMonitor.start(handler)
    }

    var nodeEntityKind: NodeEntityKind { .publisher }

    func closeEntity() throws {
        matchedMonitor.stop()
        try transportPublisher.close()
    }
}
