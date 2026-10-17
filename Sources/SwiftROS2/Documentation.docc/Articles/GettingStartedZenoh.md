# Getting Started with Zenoh

Publish and subscribe to ROS 2 topics over Zenoh in fewer than ten lines.

## Overview

Zenoh works on every platform SwiftROS2 supports. You need a running Zenoh
router (typically `rmw_zenohd`) reachable on TCP. The router locator
(`tcp/<host>:7447`) and the ROS 2 domain are the configuration you provide.

The ROS 2 domain is part of every Zenoh key expression
(`<domain>/<namespace>/<topic>/…`), so a publisher and a subscriber only see
each other when their domains are equal. The domain defaults to `0`. Pass
`domainId:` to ``ROS2Context`` to set it, and make it match the
`ROS_DOMAIN_ID` of the ROS 2 host: a context left on domain 0 publishes without
an error while a host on `ROS_DOMAIN_ID=123` receives nothing.

## Publish

```swift
import StdMsgs  // from swift-ros2-common-interfaces
import SwiftROS2

let ctx = try await ROS2Context(
    transport: .zenoh(locator: "tcp/192.168.1.10:7447"),
    domainId: 123  // the host's ROS_DOMAIN_ID; omit for the default, 0
)
let node = try await ctx.createNode(name: "talker", namespace: "/demo")
let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")

for i in 0..<100 {
    try pub.publish(StringMsg(data: "hello \(i)"))
    try await Task.sleep(nanoseconds: 100_000_000)
}

await ctx.shutdown()
```

## Subscribe

```swift
let sub = try await node.createSubscription(StringMsg.self, topic: "chatter")
for await msg in sub.messages {
    print("Received:", msg.data)
}
```

For large messages or a slow handler, deliver only the newest message with
`delivery: .latestOnly`; see <doc:Subscriptions>. To find out what is published, see
<doc:TopicGraph>.

## Matched subscriptions

A publisher can tell whether anyone is listening, so a producer can skip
expensive work (encoding an image, reading a sensor) while no subscription
matches. The behavior is the same on Zenoh, DDS, and RCL. It is exposed by
two members of ``ROS2Publisher``:

- ``ROS2Publisher/hasMatchedSubscriptions`` is `true` while at least one
  subscription matches the publisher.
- ``ROS2Publisher/onMatchedSubscriptionsChanged(_:)`` calls a handler once with
  the current state before it returns, then on every change.

```swift
import SensorMsgs  // from swift-ros2-common-interfaces

let pub = try await node.createPublisher(CompressedImage.self, topic: "camera/image/compressed")
pub.onMatchedSubscriptionsChanged { [weak pub] matched in
    guard let pub else { return }
    print("\(pub.topic):", matched ? "someone is listening" : "no subscribers")
}
```

The state is fail-open: a transport that cannot tell reports `true`, so code
that skips work without subscribers never stops publishing by mistake.

The state is sampled every 50 ms, so a change is reported up to about 50 ms
after the transport sees it. The handler runs on one private serial queue (the initial
call included) and is not called once the publisher is closed; closing the
publisher waits for a call that is already running, so the handler must not
block on a lock held by the code that closes the publisher. Capture the
publisher weakly (`[weak pub]`) so the handler does not keep it alive.

On Zenoh the state follows the router's report of matching subscribers, so it
can read `false` for a short time after the publisher is created, until the
router has answered. Delivery is unaffected: a publish with no matching
subscriber is sent as before.
