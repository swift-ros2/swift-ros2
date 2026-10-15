// Subscription.swift
// ROS 2 Subscription with AsyncStream support

import Foundation
import SwiftROS2Messages
import SwiftROS2Transport

/// ROS 2 subscription for a specific message type
///
/// Provides both AsyncStream and callback-based APIs:
/// ```swift
/// // AsyncStream (recommended)
/// let sub = try await node.createSubscription(Imu.self, topic: "imu")
/// for await message in sub.messages {
///     print("Received: \(message)")
/// }
///
/// // Callback-based
/// sub.onMessage { message in
///     print("Received: \(message)")
/// }
/// ```
///
/// A message whose payload does not decode as `M` (for example because the publisher's
/// type or version differs) is dropped. The subscription logs the first such failure,
/// then at most one line every ten seconds, and counts all of them in
/// ``decodeFailureCount``.
public final class ROS2Subscription<M: CDRDecodable & ROS2MessageType>: @unchecked Sendable, SubscriptionCloseable {
    private var transportSubscriber: (any TransportSubscriber)?
    private var continuation: AsyncStream<M>.Continuation?
    private var callbackHandler: (@Sendable (M) -> Void)?
    private let lock = NSLock()

    /// AsyncStream of received messages
    public let messages: AsyncStream<M>

    private let decodeFailures: DecodeFailureReporter

    init(topic: String, decodeFailures: DecodeFailureReporter? = nil) {
        self.decodeFailures =
            decodeFailures ?? DecodeFailureReporter(topic: topic, typeName: M.typeInfo.typeName)
        var cont: AsyncStream<M>.Continuation?
        self.messages = AsyncStream<M>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    /// Set a callback handler for received messages
    public func onMessage(_ handler: @escaping @Sendable (M) -> Void) {
        lock.lock()
        callbackHandler = handler
        lock.unlock()
    }

    /// Cancel the subscription
    public func cancel() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        callbackHandler = nil
        let sub = transportSubscriber
        lock.unlock()
        try? sub?.close()
    }

    /// The number of received messages that could not be decoded as `M` and were dropped.
    ///
    /// Counts every failure since the subscription was created, including the ones the
    /// log skipped to stay quiet. A count that grows while ``messages`` stays empty
    /// points to a type or shape mismatch with the publisher rather than to missing data.
    public var decodeFailureCount: Int {
        decodeFailures.count
    }

    // Internal: called by the node when a payload cannot be decoded
    func receiveDecodeFailure(_ error: Error) {
        decodeFailures.record(error)
    }

    // Internal: called by the node when a message arrives
    func receive(_ message: M) {
        lock.lock()
        let cont = continuation
        let callback = callbackHandler
        lock.unlock()

        cont?.yield(message)
        callback?(message)
    }

    func setTransportSubscriber(_ subscriber: any TransportSubscriber) {
        lock.lock()
        transportSubscriber = subscriber
        lock.unlock()
    }

    func closeSubscription() throws {
        cancel()
    }

    /// The topic this subscription is associated with
    public var topic: String? {
        transportSubscriber?.topic
    }
}
