// SubscriptionDelivery.swift
// How a subscription hands its messages to the caller.

/// How a subscription delivers its messages.
///
/// Pass it to ``ROS2Node/createSubscription(_:topic:qos:delivery:)`` or
/// ``ROS2Node/createSubscription(_:topic:qos:delivery:handler:)``. A subscription created
/// with ``ROS2Node/createSubscription(_:topic:qos:)`` uses ``stream``.
public enum SubscriptionDelivery: Sendable {
    /// Every message, as in 3.0: decoded on the transport's receive thread, yielded into
    /// ``ROS2Subscription/messages`` (which keeps the newest 100), then passed to the
    /// handler on the same thread. The buffer fills even when a handler is set and
    /// nobody iterates `messages`, so a `.stream` subscription of large messages holds up
    /// to 100 of them; use ``latestOnly`` for those.
    case stream

    /// Only the newest message. The transport's receive thread stores the raw payload in
    /// a one-message slot, replacing an undelivered one, and returns. A serial delivery
    /// queue owned by the subscription decodes the slot's payload and calls the handler.
    /// A payload replaced before it was delivered is never decoded. ``ROS2Subscription/messages``
    /// is empty and already finished. The reader keeps history `keepLast(1)`.
    case latestOnly
}
