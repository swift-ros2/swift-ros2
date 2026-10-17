# Examples

A `talker` / `listener` pair that mirrors [`demo_nodes_cpp`](https://github.com/ros2/demos/tree/rolling/demo_nodes_cpp)'s, plus a latched talker, service, action and parameter demos and RCL loopback checks (all documented below). The transport is picked by the first CLI argument, so one binary covers Zenoh, DDS and the native RCL backend.

| Target     | Zenoh | DDS | RCL | What it does                                      |
|------------|:-----:|:---:|:---:|---------------------------------------------------|
| `talker`   | ✅    | ✅  | ✅  | Publishes `example_interfaces/msg/String` on `/chatter` at 1 Hz |
| `listener` | ✅    | ✅  | ✅  | Subscribes to `/chatter` and prints each message  |
| `latched-talker` | ✅ | —  | —   | Publishes `depth` `example_interfaces/msg/String` samples on `/latched` with reliable TRANSIENT_LOCAL QoS, then waits 60 s for late joiners. Args: `[locator] [domain_id] [depth] [distro]`, where `distro` is `humble` or `jazzy` (default) |

Message type is `example_interfaces/msg/String`, payload is `"Hello World: N"`. Default QoS is `.sensorData` (best-effort, keep-last-10).

## Invocation

```bash
swift run talker    zenoh [tcp/<host>:7447] [domain_id]   # defaults: tcp/127.0.0.1:7447 and 0
swift run talker    dds   [domain_id]                     # default domain_id: 0
swift run listener  zenoh [tcp/<host>:7447] [domain_id]
swift run listener  dds   [domain_id]
swift run latched-talker [tcp/<host>:7447] [domain_id] [depth] [distro]   # Zenoh only; defaults: tcp/127.0.0.1:7447, 0, 1, jazzy

# Native RCL backend (rcl + rmw_cyclonedds_cpp) and CycloneDDS unicast discovery
swift run talker    rcl          [domain_id]
swift run talker    dds-unicast  <peer> [domain_id]
swift run talker    rcl-unicast  <peer> [domain_id]
swift run listener  rcl          [domain_id]
swift run listener  dds-unicast  <peer> [domain_id]
swift run listener  rcl-unicast  <peer> [domain_id]
```

The first argument selects the transport (`zenoh`, `dds`, `rcl`, `dds-unicast` or `rcl-unicast`). Remaining arguments are transport-specific:

- **zenoh:** `[locator] [domain_id]` — the router locator, plus the ROS 2 domain ID (domain is baked into the Zenoh key expression as `<domain>/<namespace>/<topic>/…`, so publisher and subscriber must agree).
- **dds:** `[domain_id]` — the ROS 2 domain ID for CycloneDDS discovery (multicast).
- **rcl:** `[domain_id]` — the same, on the native RCL backend (`.rcl(domainId:)`, `rmw_cyclonedds_cpp`). It needs a build graph that has the RCL backend: the default Apple graph, or Linux with `SWIFT_ROS2_ENABLE_RCL=1`; elsewhere (including the zenoh RCL variant) the context throws `TransportError.unsupportedFeature`.
- **dds-unicast / rcl-unicast:** `<peer> [domain_id]` — the peer address is required; the example builds one peer on port `7400 + domain_id * 250` and uses `.ddsUnicast(peers:domainId:)` (wire CycloneDDS) or `.rclUnicast(peers:domainId:)` (RCL). This exercises the generated CycloneDDS discovery XML on networks without multicast.

All arguments except the unicast peer default, so `swift run talker` alone targets a local Zenoh router at `tcp/127.0.0.1:7447` with domain `0`.

The other examples take the same transport arguments:

```bash
swift run srv-server      <transport> [args…]     # example_interfaces/srv/Trigger server on /trigger
swift run srv-client      <transport> [args…]
swift run action-server   <transport> [args…]     # Fibonacci action server on /fibonacci
swift run action-client   <transport> [args…] [order]   # order (default 10) follows the transport arguments
swift run parameter-demo  <transport> [args…]
```

For example `swift run action-client rcl-unicast 192.168.1.10 123 15` sends a Fibonacci goal of order 15 on domain 123 to the peer at `192.168.1.10`, and `swift run action-client dds 0 15` does the same over multicast DDS on domain 0.

### Loopback checks

`crcl-loopback`, `crcl-svc-loopback`, `crcl-action-loopback` and `crcl-graph-loopback` are self-contained RCL smoke tests (topic, service plus parameters, action, and `ROS2Context.topicGraph()` respectively) that take no arguments and exist only in RCL-enabled build graphs. They run on `.rcl(domainId: 0)` by default; `crcl-graph-loopback` uses domain 82 so that no other process adds topics to its graph. Set `CRCL_ZENOH_LOCATOR` to run the same loopback over `.zenoh(locator:)` instead, which is how the zenoh `rmw_zenoh_cpp` build variant is exercised (that variant rejects `.rcl`). Build with `SWIFT_ROS2_RCL_RMW=zenoh` as well: on the default graph `.zenoh` resolves to the wire zenoh-pico transport, so the loopback would pass without touching RCL. A Zenoh router must be listening at the locator (for example `ros2 run rmw_zenoh_cpp rmw_zenohd`, or a standalone `zenohd --listen tcp/127.0.0.1:7447 --no-multicast-scouting`):

```bash
SWIFT_ROS2_RCL_RMW=zenoh CRCL_ZENOH_LOCATOR=tcp/127.0.0.1:7447 swift run crcl-loopback
```

The variant resolves to the pinned release xcframework `CRos2Zenoh`; add `SWIFT_ROS2_RCL_LOCAL=1` to use a locally built `CRos2Zenoh` instead (`RMW_VARIANT=zenoh Scripts/build-ros2-xcframework.sh`).

`crcl-graph-loopback` runs two contexts in one process. One publishes `/graph_ns/map` (reliable, transient-local), `/graph_ns/scan` (best effort, volatile) and a Fibonacci action server from node `graph_pub` in `/graph_ns`; the other, which has no node of its own, polls `topicGraph()` until it lists those topics with their ROS types, QoS and owning node, including the hidden `fibonacci/_action/feedback` and `_action/status` topics, and then until they are gone after the first context shuts down. It also prints whether `/rosout` and `/parameter_events` are listed. Neither is in this run, on either rmw variant: swift-ros2's RCL nodes publish no `/rosout`, and `/parameter_events` only once a node emits a parameter event.

### Delivery memory soak

`delivery-soak` measures the memory of a subscription under load: it publishes a 1280×720 `rgb8` `sensor_msgs/Image` at 30 Hz to a subscription in the same process whose handler sleeps 100 ms, and prints the footprint delta over the measured window. The nightly `memory-soak` workflow runs it on each wire transport, with `.latestOnly` and with `.stream` for comparison:

```bash
swift run -c release delivery-soak zenoh latest --locator tcp/127.0.0.1:7447   # needs a router
swift run -c release delivery-soak dds   stream --domain 76 --duration-s 30
```

Options: `--warmup-s` (15), `--duration-s` (60), `--rate-hz` (30), `--handler-ms` (100), `--width` / `--height` (1280×720), `--best-effort` (reliable by default).

## Prerequisites

- macOS with Xcode 16+ **or** Ubuntu 22.04 / 24.04 with Swift 5.9+ and `ros-<distro>-cyclonedds` installed. See the top-level [`README.md`](../../README.md#installation) for per-platform setup.
- A ROS 2 install on the peer side (Humble / Jazzy / Kilted / Lyrical / Rolling). These demos default to the Jazzy wire format; edit `.distro:` on the `ROS2Context` call if you need Humble.
- `ros-<distro>-example-interfaces` installed on the peer: the tutorials below echo and publish `example_interfaces/msg/String`, which `ros2 topic echo` / `pub` can only resolve if that package is present.
- **Zenoh only:** a running `rmw_zenoh_cpp` router (`ros2 run rmw_zenoh_cpp rmw_zenohd`) that both sides can reach over TCP.
- **DDS only:** a multicast-capable LAN on a shared `ROS_DOMAIN_ID` (default `0`). On Wi-Fi without multicast, use the `dds-unicast` arm — see below.

## Zenoh tutorial

### 1. Start a router

On any host reachable from both the Swift side and the ROS 2 side:

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
ros2 run rmw_zenoh_cpp rmw_zenohd            # listens on tcp/0.0.0.0:7447
```

### 2. Swift talker → ROS 2 listener

Terminal A (Swift publisher):

```bash
swift run talker zenoh tcp/<router-host>:7447
# Publishing: 'Hello World: 1'
# Publishing: 'Hello World: 2'
```

Terminal B (ROS 2 subscriber):

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
ros2 topic echo /chatter example_interfaces/msg/String
# data: 'Hello World: 1'
# ---
# data: 'Hello World: 2'
```

### 3. ROS 2 talker → Swift listener

Terminal A (ROS 2 publisher):

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
ros2 topic pub -r 1 /chatter example_interfaces/msg/String "{data: 'Hello World: 1'}"
```

Terminal B (Swift subscriber):

```bash
swift run listener zenoh tcp/<router-host>:7447
# Listening on /chatter...
# I heard: 'Hello World: 1'
```

### 4. Swift ↔ Swift

Runs entirely within swift-ros2, no ROS 2 install needed on either side:

```bash
# Terminal A
swift run talker   zenoh tcp/<router-host>:7447

# Terminal B
swift run listener zenoh tcp/<router-host>:7447
```

You still need a `rmw_zenohd` router in the middle — Zenoh peers rendezvous through it.

## DDS tutorial

CycloneDDS discovery is peer-to-peer, so there is no router. Just run on the same LAN + same `ROS_DOMAIN_ID`.

### 1. Swift talker → ROS 2 listener

Terminal A (Swift publisher):

```bash
swift run talker dds 0             # ROS_DOMAIN_ID = 0
```

Terminal B (ROS 2 subscriber):

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=0
ros2 topic echo /chatter example_interfaces/msg/String
```

### 2. ROS 2 talker → Swift listener

Terminal A (ROS 2 publisher):

```bash
source /opt/ros/jazzy/setup.bash
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export ROS_DOMAIN_ID=0
ros2 topic pub -r 1 /chatter example_interfaces/msg/String "{data: 'Hello World: 1'}"
```

Terminal B (Swift subscriber):

```bash
swift run listener dds 0
# Listening on /chatter...
# I heard: 'Hello World: 1'
```

### 3. Swift ↔ Swift

Two Swift processes on the same LAN + `ROS_DOMAIN_ID`, no router, no ROS 2 install:

```bash
# Terminal A
swift run talker   dds 0

# Terminal B
swift run listener dds 0
```

### Wi-Fi (no multicast)

On networks that drop multicast, use the unicast arms; each takes the peer's IP address (required) and an optional domain ID:

```bash
swift run talker   dds-unicast 192.168.1.10 0    # wire CycloneDDS, .ddsUnicast(peers:)
swift run listener dds-unicast 192.168.1.10 0
swift run talker   rcl-unicast 192.168.1.10 0    # native RCL, .rclUnicast(peers:)
```

`<peer>` is the address of the host that runs the other end, not of this host. The discovery port is derived from the domain (`7400 + domain_id * 250`, so `7400` on domain 0). The other examples (`srv-server`, `action-client`, ...) accept the same arms. In your own code the `dds-unicast` arm is:

```swift
transport = .ddsUnicast(
    peers: [DDSPeer.peer(address: "192.168.1.10", domainId: 0)],
    domainId: 0
)
```

Both sides must list each other. On the ROS 2 side, set `CYCLONEDDS_URI` — see [CycloneDDS config docs](https://cyclonedds.io/docs/cyclonedds/latest/config/config_file_reference.html) and the notes in the top-level README.

## Anatomy of a demo

Every example follows the same four steps. The examples publish `StringMsg` from
`SwiftROS2ExampleInterfaces`, a target internal to this package; in your own package, use a
type from [swift-ros2-common-interfaces](https://github.com/swift-ros2/swift-ros2-common-interfaces)
(`import StdMsgs` for `std_msgs/msg/String`) or generate one with `swift-ros2-gen`.

```swift
import SwiftROS2
import SwiftROS2ExampleInterfaces  // internal: StringMsg = example_interfaces/msg/String

// 1. Open a context over the chosen transport.
let ctx = try await ROS2Context(
    transport: .zenoh(locator: "tcp/127.0.0.1:7447"),   // or .ddsMulticast(domainId: 0)
    distro: .jazzy
)

// 2. Create a node under that context.
let node = try await ctx.createNode(name: "talker")

// 3a. Publisher side.
let pub = try await node.createPublisher(StringMsg.self, topic: "chatter")
try pub.publish(StringMsg(data: "Hello World: 1"))

// 3b. Subscription side.
let sub = try await node.createSubscription(StringMsg.self, topic: "chatter")
for await msg in sub.messages { print(msg.data) }

// 4. Tear down.
await ctx.shutdown()
```

Swap `.zenoh(...)` ↔ `.ddsMulticast(...)` to switch transports — everything above step 1 is identical. That's the whole point of the umbrella API, and it's why the talker / listener demos collapse into a single binary each.

## Troubleshooting

- **`ros2 topic echo` prints nothing but `ros2 topic list` shows `/chatter`** — wire format mismatch. Pin `.distro:` on the Swift side to match the ROS 2 distro (e.g. `.humble` for Humble's pre-type-hash wire schema).
- **Connection refused on Zenoh** — router isn't running, wrong IP, or firewall blocks TCP `7447`.
- **DDS sees nothing** — wrong `ROS_DOMAIN_ID`, or the network drops multicast. Switch to the `dds-unicast` arm (`.ddsUnicast`).
- **`swift run` fails to find `talker`** — run it from the repository root, not a subdirectory; SPM resolves targets relative to `Package.swift`.
