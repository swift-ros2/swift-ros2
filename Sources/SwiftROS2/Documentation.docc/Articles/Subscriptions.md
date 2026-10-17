# Receiving Messages

Choose how a subscription delivers its messages, and attach its handler before the
first sample can arrive.

## Overview

A ``ROS2Subscription`` delivers in one of two ``SubscriptionDelivery`` modes:

- ``SubscriptionDelivery/stream`` delivers every message. It is what
  ``ROS2Node/createSubscription(_:topic:qos:)`` creates, unchanged from 3.0.
- ``SubscriptionDelivery/latestOnly`` delivers only the newest message, for large
  messages and slow handlers: camera images, point clouds, maps.

Three overloads create a subscription:

| Call | Delivery | Handler |
|---|---|---|
| ``ROS2Node/createSubscription(_:topic:qos:)`` | `.stream` | none; iterate ``ROS2Subscription/messages`` or call ``ROS2Subscription/onMessage(_:)`` |
| ``ROS2Node/createSubscription(_:topic:qos:delivery:)`` | the one you pass | none; call ``ROS2Subscription/onMessage(_:)`` |
| ``ROS2Node/createSubscription(_:topic:qos:delivery:handler:)`` | the one you pass | attached before the transport subscriber exists |

A call without `delivery:` resolves to the first overload, so 3.0 code keeps its
behavior. The two newer overloads take `qos:` without a default.

## Stream delivery

Each message is decoded on the transport's receive thread (a zenoh-pico read task, a
CycloneDDS listener thread or an rcl wait thread), yielded into
``ROS2Subscription/messages``, then passed to the handler on the same thread:

```swift
let sub = try await node.createSubscription(Imu.self, topic: "imu")
for await imu in sub.messages {
    print(imu.linearAcceleration)
}
```

`messages` keeps the newest 100 messages whether or not anyone iterates it, so a
`.stream` subscription that only uses its handler still holds up to 100 decoded
messages. A slow handler holds the receive thread, and on wire Zenoh one read task
serves the whole session.

## Latest-only delivery

```swift
let camera = try await node.createSubscription(
    Image.self, topic: "camera/image_raw", qos: .sensorData, delivery: .latestOnly
) { image in
    render(image)
}
```

The transport's receive thread stores the raw payload in a one-message slot, replacing
one that was not delivered yet, and returns. It never decodes, never calls your code
and never waits. A serial dispatch queue owned by the subscription takes the slot,
decodes it and calls the handler, until the slot is empty. So:

- a slow handler never blocks the transport, and the handler never runs concurrently
  with itself;
- each message the handler gets arrived after the previous one, and the newest one is
  always delivered;
- a payload replaced before it was delivered is never decoded, and at most one payload
  waits while one message is being handled;
- ``ROS2Subscription/messages`` is empty and already finished, so `for await` ends at
  once;
- the reader keeps history `keepLast(1)`, whatever the `qos` history says. History
  depth is not a matching policy, so this changes no match;
- ``ROS2Subscription/decodeFailureCount`` counts failures among the delivered payloads
  only.

Without a handler, payloads keep replacing the slot. ``ROS2Subscription/onMessage(_:)``
delivers the newest one as soon as it is set.

## Attaching the handler at creation

``ROS2Node/createSubscription(_:topic:qos:delivery:handler:)`` stores the handler before
the transport subscriber is created, so nothing that arrives during creation is missed.
That matters for transient-local topics (``QoSProfile/latched``), whose cached samples
can arrive before `createSubscription` returns:

```swift
let staticTransforms = try await node.createSubscription(
    TFMessage.self, topic: "/tf_static", qos: .latched, delivery: .stream
) { message in
    store(message.transforms)
}
```

How a late joiner gets the cached samples depends on the transport:

- **Wire Zenoh.** The subscription queries the caches of the topic's transient-local
  publishers once, when it is created, and delivers the replies before the live samples
  that arrived meanwhile. The query waits at most 5 s, and up to 1000 live samples are
  held while it runs. A publisher that appears later is not queried; its later publishes
  reach the subscription directly. A volatile publisher has no cache.
- **Wire DDS and RCL.** CycloneDDS and rmw replay the cached samples while the reader is
  created.

## Cancelling

``ROS2Subscription/cancel()`` finishes `messages`, drops the handler and closes the
transport subscriber. It does not wait for a handler call in progress. On a
`.latestOnly` subscription it also drops the undelivered payload; at most one handler
call that had already passed its last check may still run after `cancel()` returns,
and no later call starts. Calling `cancel()` from inside a `.latestOnly` handler is
safe. On RCL, calling it from inside a `.stream` handler stops delivery but leaks the
rcl subscription, because rcl cannot destroy it from the thread that runs the handler.
