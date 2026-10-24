// Subscription.swift
// ROS 2 Subscription with AsyncStream support

import Foundation
import SwiftROS2CDR
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
///
/// // Newest message only, handler attached before the first sample can arrive
/// let images = try await node.createSubscription(
///     Image.self, topic: "camera/image_raw", qos: .sensorData, delivery: .latestOnly
/// ) { image in
///     show(image)
/// }
/// ```
///
/// How messages reach ``messages`` and the handler depends on the subscription's
/// ``SubscriptionDelivery``.
///
/// A message whose payload does not decode as `M` (for example because the publisher's
/// type or version differs) is dropped. The subscription logs the first such failure,
/// then at most one line every ten seconds, and counts all of them in
/// ``decodeFailureCount``.
public final class ROS2Subscription<M: CDRDecodable & ROS2MessageType>: @unchecked Sendable, NodeEntity {
    private var transportSubscriber: (any TransportSubscriber)?
    private var continuation: AsyncStream<M>.Continuation?
    private var callbackHandler: (@Sendable (M) -> Void)?
    private let lock = NSLock()

    /// AsyncStream of received messages.
    ///
    /// On a ``SubscriptionDelivery/stream`` subscription it buffers the newest 100
    /// messages, whether or not anyone iterates it. On a ``SubscriptionDelivery/latestOnly``
    /// subscription it is empty and already finished, so `for await` ends at once; use
    /// the handler instead.
    public let messages: AsyncStream<M>

    private let decodeFailures: DecodeFailureReporter

    /// How this subscription delivers its messages.
    let delivery: SubscriptionDelivery
    /// The distribution whose message schemas the decoder reads.
    private let distro: ROS2Distro

    // `.latestOnly` state, guarded by `lock`. `pending` is the one-message slot; `drainScheduled`
    // is true from the moment a drain is queued until it finds the slot empty; `closed` is set by
    // `cancel()` and stops every later handler call.
    private var pending: Data?
    private var drainScheduled = false
    private var closed = false
    private let deliveryQueue: DispatchQueue?

    init(
        topic: String,
        delivery: SubscriptionDelivery = .stream,
        handler: (@Sendable (M) -> Void)? = nil,
        distro: ROS2Distro = .jazzy,
        decodeFailures: DecodeFailureReporter? = nil
    ) {
        self.decodeFailures =
            decodeFailures ?? DecodeFailureReporter(topic: topic, typeName: M.typeInfo.typeName)
        self.delivery = delivery
        self.distro = distro
        self.callbackHandler = handler
        var cont: AsyncStream<M>.Continuation?
        self.messages = AsyncStream<M>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            cont = continuation
        }
        switch delivery {
        case .stream:
            self.continuation = cont
            self.deliveryQueue = nil
        case .latestOnly:
            cont?.finish()
            self.continuation = nil
            self.deliveryQueue = DispatchQueue(label: "swift-ros2.delivery.\(topic)", qos: .userInitiated)
        }
    }

    /// Sets the handler for received messages, replacing the current one.
    ///
    /// On a ``SubscriptionDelivery/stream`` subscription the handler runs on the
    /// transport's receive thread, after the message is yielded into ``messages``. On a
    /// ``SubscriptionDelivery/latestOnly`` subscription it runs on the subscription's serial
    /// delivery queue, never concurrently with itself; the newest message that arrived
    /// before the handler was set is delivered once it is set.
    public func onMessage(_ handler: @escaping @Sendable (M) -> Void) {
        lock.lock()
        callbackHandler = handler
        let schedule = takeDrainTicketLocked()
        lock.unlock()
        if schedule { scheduleDrain() }
    }

    /// Cancels the subscription.
    ///
    /// Finishes ``messages``, drops the handler and closes the transport subscriber. It does
    /// not wait for a handler call in progress. On a ``SubscriptionDelivery/latestOnly``
    /// subscription it also drops the undelivered message, and at most one handler call that
    /// had already started its last check may still run after `cancel()` returns; no later
    /// call starts. Calling it from inside a `.latestOnly` handler is safe, because that
    /// handler does not run on the transport's thread. On the RCL transport, calling it from
    /// inside a ``SubscriptionDelivery/stream`` handler behaves as in 3.0: the subscription
    /// stops delivering, but the rcl subscription cannot be destroyed from the thread that
    /// runs the handler and is leaked.
    public func cancel() {
        lock.lock()
        closed = true
        let dropped = pending
        pending = nil
        continuation?.finish()
        continuation = nil
        callbackHandler = nil
        let sub = transportSubscriber
        lock.unlock()
        withExtendedLifetime(dropped) {}
        try? sub?.close()
    }

    /// The number of received messages that could not be decoded as `M` and were dropped.
    ///
    /// Counts every failure since the subscription was created, including the ones the
    /// log skipped to stay quiet. A count that grows while ``messages`` stays empty
    /// points to a type or shape mismatch with the publisher rather than to missing data.
    /// A ``SubscriptionDelivery/latestOnly`` subscription decodes only the payloads it
    /// delivers, so it counts the failures among those; a replaced payload is never decoded.
    public var decodeFailureCount: Int {
        decodeFailures.count
    }

    // Internal: records a payload that could not be decoded as `M`.
    func receiveDecodeFailure(_ error: Error) {
        decodeFailures.record(error)
    }

    // Internal: called by the transport handler with each raw payload, on its receive thread.
    func receivePayload(_ data: Data) {
        switch delivery {
        case .stream:
            do {
                receive(try decode(data))
            } catch {
                // The message is dropped; the subscription counts and logs the failure.
                receiveDecodeFailure(error)
            }
        case .latestOnly:
            // O(1) under the lock: swap the slot and queue a drain when none is pending.
            // Never decodes, never calls user code, never waits.
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            let replaced = pending
            pending = data
            let schedule = takeDrainTicketLocked()
            lock.unlock()
            // A large replaced payload is freed here, outside the lock.
            withExtendedLifetime(replaced) {}
            if schedule { scheduleDrain() }
        }
    }

    private func decode(_ data: Data) throws -> M {
        let decoder = try CDRDecoder(data: data, distro: distro)
        return try M(from: decoder)
    }

    /// Whether the caller must queue a drain: a `.latestOnly` subscription that is open, has a
    /// handler and a waiting payload, and has no drain queued. Marks the drain as queued.
    /// Call with `lock` held.
    private func takeDrainTicketLocked() -> Bool {
        guard delivery == .latestOnly, !closed, !drainScheduled, pending != nil, callbackHandler != nil
        else { return false }
        drainScheduled = true
        return true
    }

    private func scheduleDrain() {
        deliveryQueue?.async { self.drain() }
    }

    /// Runs on the delivery queue: take the slot, decode outside the lock, call the handler,
    /// repeat until the slot is empty or the subscription is closed.
    private func drain() {
        while true {
            lock.lock()
            guard !closed, let data = pending else {
                drainScheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let message: M
            do {
                message = try decode(data)
            } catch {
                decodeFailures.record(error)
                continue
            }

            // The last check before user code: `cancel()` after this point lets at most this
            // one call run.
            lock.lock()
            guard !closed, let handler = callbackHandler else {
                drainScheduled = false
                lock.unlock()
                return
            }
            lock.unlock()
            handler(message)
        }
    }

    // Internal: delivers one decoded message on a `.stream` subscription.
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

    var nodeEntityKind: NodeEntityKind { .subscription }

    func closeEntity() throws {
        cancel()
    }

    /// The topic this subscription is associated with
    public var topic: String? {
        transportSubscriber?.topic
    }
}
