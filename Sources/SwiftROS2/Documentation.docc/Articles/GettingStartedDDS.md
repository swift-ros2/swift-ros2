# Getting Started with DDS

Use CycloneDDS directly (no router) on Apple platforms or Linux.

## Overview

DDS uses multicast discovery by default. If your network does not allow
multicast (e.g. many Wi-Fi setups), switch to unicast and supply the peer
address(es).

## Multicast

```swift
import StdMsgs  // from swift-ros2-common-interfaces
import SwiftROS2

let ctx = try await ROS2Context(transport: .ddsMulticast(domainId: 0))
let node = try await ctx.createNode(name: "talker")
let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")
```

## Unicast (Wi-Fi without multicast)

```swift
let peers = [DDSPeer(address: "192.168.1.10", port: 7400)]
let ctx = try await ROS2Context(transport: .ddsUnicast(peers: peers, domainId: 0))
```

## Domain ID and discovery port

CycloneDDS computes the discovery port as `7400 + domainId * 250`. SwiftROS2
exposes the same formula via `DDSPeer.discoveryPort(forDomain:)`.

The port is sent to CycloneDDS as part of the peer, so it has to match the domain you are
joining. On any domain other than 0 the `port: 7400` default is wrong — build peers with the
factory instead, which applies the formula for you. Each peer is also given to CycloneDDS as the
bare host, so discovery reaches every ROS 2 node on that host and not only the most recently
started one: on Linux, all of a host's participants share the discovery port, and a unicast
packet to that port reaches only one of them.

```swift
let peers = [DDSPeer.peer(address: "192.168.1.10", domainId: 5)]
let ctx = try await ROS2Context(transport: .ddsUnicast(peers: peers, domainId: 5))
```

## Matched subscriptions

``ROS2Publisher/hasMatchedSubscriptions`` and
``ROS2Publisher/onMatchedSubscriptionsChanged(_:)`` report whether a
subscription matches the publisher. On DDS the state is the writer's
publication-matched count, sampled every 50 ms. See "Matched subscriptions" in
<doc:GettingStartedZenoh> for the rules that apply to every transport.
