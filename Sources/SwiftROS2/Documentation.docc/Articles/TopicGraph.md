# Discovering Topics

List the published topics of a ROS domain, with each publisher's QoS and node.

## Overview

``ROS2Context/topicGraph()`` returns a snapshot of every topic in the context's ROS
domain that has at least one known publisher, the information `ros2 topic list -t` and
`ros2 topic info -v` show. It works on wire Zenoh, wire DDS and RCL, and needs no node.

Each ``TopicInfo`` is one topic name and one type. A topic published with two types
appears twice, with the same ``TopicInfo/name``. Its ``TopicInfo/publishers`` hold one
``EndpointQoS`` per publisher: reliability, durability, node name and node namespace.
The result is sorted by name and then type; the publishers by node namespace, node
name, reliability and durability.

```swift
import SwiftROS2

let context = try await ROS2Context(
    transport: .zenoh(locator: "tcp/192.168.1.10:7447"), domainId: 123)
for topic in try await context.topicGraph() {
    print(topic.name, topic.typeName)
    for publisher in topic.publishers {
        print("  \(publisher.nodeNamespace) \(publisher.nodeName)",
              publisher.reliability, publisher.durability)
    }
}
```

Names are absolute (`/kachaka/mapping/map`), types are in ROS form
(`nav_msgs/msg/OccupancyGrid`, the same string as `typeInfo.typeName` of the generated
Swift type), and node namespaces are absolute, `/` for the root namespace.

## What the snapshot contains

- **Hidden topics.** The `/<action>/_action/feedback` and `/<action>/_action/status`
  topics of action servers are listed. Service topics are not.
- **Your own publishers.** The context's own publishers, and those of other contexts
  in the process, are listed. Drop them by node name and namespace (see below).
- **Unknown nodes.** A publisher whose node the transport cannot attribute is listed
  with `_NODE_NAME_UNKNOWN_` and `_NODE_NAMESPACE_UNKNOWN_`, as `ros2 topic info -v`
  does, never dropped. On wire DDS this is a writer whose node's `ros_discovery_info`
  record has not arrived yet, or a writer of a non-ROS participant.
- **Conservative QoS.** A reliability the transport cannot read as RELIABLE is reported
  as ``QoSProfile/Reliability/bestEffort``, and a durability it cannot read as
  TRANSIENT_LOCAL (or, on wire DDS, TRANSIENT or PERSISTENT) as
  ``QoSProfile/Durability/volatile``.

## Choosing a subscriber QoS

A subscription matches a DDS publisher only when it asks for no more than the publisher
offers: a reliable reader does not match a best-effort writer, and a transient-local
reader does not match a volatile one. To subscribe to a topic you did not publish, ask
for reliable only when every publisher is reliable, and for transient-local only when
every publisher is transient-local. The conservative mapping above keeps this rule
safe: a value the transport could not read can only lower the result, and a lowered
reader still matches every writer.

```swift
let ownNamespace = "/viewer"
let graph = try await context.topicGraph()
guard
    let map = graph.first(where: { $0.name == "/map" && $0.typeName == "nav_msgs/msg/OccupancyGrid" })
else { return }

// Drop this app's own publishers; the graph lists them too.
let publishers = map.publishers.filter { $0.nodeNamespace != ownNamespace }
guard !publishers.isEmpty else { return }

let qos = QoSProfile(
    reliability: publishers.allSatisfy { $0.reliability == .reliable } ? .reliable : .bestEffort,
    durability: publishers.allSatisfy { $0.durability == .transientLocal } ? .transientLocal : .volatile,
    history: .keepLast(1))
let subscription = try await node.createSubscription(
    OccupancyGrid.self, topic: map.name, qos: qos, delivery: .latestOnly
) { grid in
    show(grid)
}
```

The graph cannot list a publisher that has not been discovered yet. If it lists only a
transient-local publisher and a volatile one appears later, a transient-local DDS reader
does not match the newcomer. Poll the graph and re-resolve the QoS when the set of
publishers changes.

## Freshness per transport

| | Wire Zenoh | Wire DDS | RCL |
|---|---|---|---|
| Source | the router, asked for the publishers' liveliness tokens on every call | CycloneDDS discovery (`DCPSPublication`) and `ros_discovery_info`, read locally | rmw's graph cache, read locally |
| A remote publisher that went away | gone on the next call | listed until its participant's lease expires | on `rmw_cyclonedds_cpp`, listed until the lease expires; on `rmw_zenoh_cpp`, gone when its token is withdrawn |
| Right after the context opens | complete once the router answers | partial until discovery settles | partial until discovery settles |
| Humble hosts | yes | yes | no |

Discovery on wire DDS and RCL is asynchronous. For the first seconds after a context
opens, the result can miss remote publishers, and on wire DDS a listed publisher can
carry `_NODE_NAME_UNKNOWN_` until its node's record arrives. Do not read an early empty
or partial result as "nothing is published".

On RCL the graph is read through an internal node, `_swift_ros2_graph` in `/`, which
the first call creates and ``ROS2Context/shutdown()`` destroys. The leading underscore
hides it from `ros2 node list` unless `-a` is passed.

## Polling and errors

The call does not observe task cancellation, and it never runs a blocking read on the
Swift concurrency cooperative pool: on wire Zenoh it waits for the router's answer for
at most 1.5 s, and on wire DDS and RCL the cache is read on a serial dispatch queue
owned by the session. A poll every few seconds is enough for most uses.

- ``TransportError/notConnected`` — the context is shut down, or the wire Zenoh session
  has lost its router. Not recoverable: create a new context.
- ``TransportError/sessionUnhealthy(_:)`` — recoverable. On wire Zenoh, the router did
  not answer within 1.5 s or the query failed; the call never returns a partial list.
  On wire DDS and RCL, the discovery cache could not be read.
- ``TransportError/unsupportedFeature(_:)`` — the transport has no graph support.

Treat `.sessionUnhealthy` as a missed poll: keep the last graph and try again.

zenoh-pico does not time out a liveliness query the router never finishes. A wire Zenoh
call made while such a query is still pending, for up to 10 s, throws
`.sessionUnhealthy` at once and starts nothing; after that the query is abandoned and the
next call starts a new one. When three abandoned queries are pending, the session is
graph-stalled: ``ROS2Context/topicGraph()`` throws `.sessionUnhealthy` at once and
``ROS2Context/isConnected`` is `false` until the context is rebuilt, while publishers
and subscriptions keep working. A watchdog that rebuilds the context when
`isConnected` turns false therefore also recovers a stalled graph.
