# swift-ros2

> swift-ros2 moved from `youtalk/swift-ros2` to `swift-ros2/swift-ros2`. The old URL redirects
> and every published tag keeps resolving. Do not use both URLs in one dependency graph:
> SwiftPM treats them as two locations for the same `swift-ros2` package.
> (Maintainers: never create a new `youtalk/swift-ros2` repository; it would break the redirect.)

[![Apple CI](https://img.shields.io/github/actions/workflow/status/swift-ros2/swift-ros2/ci.yml?branch=main&label=Apple)](https://github.com/swift-ros2/swift-ros2/actions/workflows/ci.yml)
[![Linux CI](https://img.shields.io/github/actions/workflow/status/swift-ros2/swift-ros2/ci.yml?branch=main&label=Linux)](https://github.com/swift-ros2/swift-ros2/actions/workflows/ci.yml)
[![Windows CI](https://img.shields.io/github/actions/workflow/status/swift-ros2/swift-ros2/ci.yml?branch=main&label=Windows)](https://github.com/swift-ros2/swift-ros2/actions/workflows/ci.yml)
[![Android CI](https://img.shields.io/github/actions/workflow/status/swift-ros2/swift-ros2/ci.yml?branch=main&label=Android)](https://github.com/swift-ros2/swift-ros2/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/swift-ros2/swift-ros2?label=release&sort=semver)](https://github.com/swift-ros2/swift-ros2/releases)
[![ROS 2](https://img.shields.io/badge/ROS%202-Humble%20%7C%20Jazzy%20%7C%20Kilted%20%7C%20Lyrical%20%7C%20Rolling-22314E.svg)](https://docs.ros.org)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![SPI Swift compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fswift-ros2%2Fswift-ros2%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/swift-ros2/swift-ros2)
[![SPI platform compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fswift-ros2%2Fswift-ros2%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/swift-ros2/swift-ros2)

Native Swift client library for ROS 2. Publish and subscribe to ROS 2 topics over **Zenoh** or **DDS** on every consumer device OS that runs Swift — no `rcl` cross-compile for you, no bridge. A single `.package(url:)` on Apple, `apt install ros-<distro>-cyclonedds` on Linux, a vanilla `swift build` on Windows / Android. The API is Swift-native (`async`/`await`, `AsyncStream`, `Sendable`) and round-trip compatible with `rmw_zenoh_cpp` / `rmw_cyclonedds_cpp`.

Shipping on the SemVer-stable **3.x** line (latest tag in the release badge). 3.0 split the project into three packages; see [Packages](#packages) and [`MIGRATION.md`](MIGRATION.md). Extracted from [Conduit, powered by ROS](https://apps.apple.com/app/id6757171237) — used cumulatively by **10,000+ ROS developers** and a former **#4** in the App Store's Developer Tools category.

## Quick Start

```swift
import SwiftROS2
import CommonInterfaces   // standard messages (sensor_msgs, std_msgs, …) from swift-ros2-common-interfaces

// Publish an IMU message over Zenoh. The ROS 2 domain is part of every Zenoh key
// expression and defaults to 0: pass `domainId:` to match the host's ROS_DOMAIN_ID.
let context = try await ROS2Context(
    transport: .zenoh(locator: "tcp/192.168.1.100:7447"), distro: .jazzy,
    domainId: 123)
let node = try await context.createNode(name: "sensor_node", namespace: "/ios")
let pub = try await node.createPublisher(Imu.self, topic: "imu")
try pub.publish(Imu(
    header: Header.now(frameId: "imu_link"),
    linearAcceleration: Vector3(x: 0, y: 0, z: 9.81)))

// Same over DDS — identical Node / Publisher / Subscription API from here on.
let ddsContext = try await ROS2Context(transport: .ddsMulticast(domainId: 123))

// Subscribe.
let sub = try await node.createSubscription(Imu.self, topic: "imu")
for await msg in sub.messages { print("accel: \(msg.linearAcceleration)") }
```

A Zenoh publisher and a `ros2` subscriber only see each other when their domains agree, because the domain is the first segment of the key expression (`<domain>/<namespace>/<topic>/…`). The default is `0`; when the host runs with `ROS_DOMAIN_ID=123`, a context left on domain 0 publishes without any error and the host receives nothing. `ROS2Context(transport:distro:domainId:)` is the way to set the domain; `domainId` takes precedence over the domain carried by the `TransportConfig` (`.zenoh(locator:domainId:)`, `.ddsMulticast(domainId:)`, …).

### Services

`ROS2Service<S>` / `ROS2Client<S>` round-trip a typed request / response over either transport (Zenoh queryables or DDS rq/rr topics). Failures surface as `ServiceError` (`.timeout`, `.handlerFailed`, `.serviceUnavailable`, `.taskCancelled`, …).

```swift
// `TriggerSrv` is std_srvs/srv/Trigger from the `StdSrvs` module (re-exported by `CommonInterfaces`); any `ROS2ServiceType` works.
let svc = try await node.createService(TriggerSrv.self, name: "/trigger") { _ in
    TriggerSrv.Response(success: true, message: "ok")
}
let cli = try await node.createClient(TriggerSrv.self, name: "/trigger")
try await cli.waitForService(timeout: .seconds(5))
let resp = try await cli.call(.init(), timeout: .seconds(5))
```

### Parameters, Actions, and runnable examples

Declare typed parameters (`node.declareParameter` + on-set veto callbacks; interoperates with `ros2 param list/set` and `/parameter_events`) and typed actions (`node.createActionServer` / `createActionClient` with goal handles and feedback `AsyncStream`). End-to-end `talker` / `listener` demos modeled on `demo_nodes_cpp` — `swift run talker zenoh`, `swift run listener dds`, `swift run parameter-demo zenoh` — live under [`Sources/Examples/README.md`](Sources/Examples/README.md).

## Backends: RCL, with an internal wire fallback

Two backends sit behind one backend-agnostic umbrella API:

- **Native RCL backend** — the real upstream stack (`rcl` + `rmw_zenoh_cpp` / `rmw_cyclonedds_cpp`), so type hashes, QoS semantics, the node graph, and introspection match upstream by construction. **Apple:** prebuilt `CRos2` / `CRos2Zenoh` xcframeworks downloaded from the release URL, one rmw baked per build variant. They are built from ROS 2 Lyrical (`release-lyrical-20260807`: rcl 10.4, `rmw_cyclonedds_cpp` 4.1 with CycloneDDS 11.0.1, or `rmw_zenoh_cpp` 0.10.7 with Zenoh 1.10.1) and interoperate with Jazzy and Lyrical hosts (see "Interop" below). `Scripts/build-ros2-xcframework.sh` rebuilds them locally, and `SWIFT_ROS2_RCL_LOCAL=1` picks up the local build. The RCL backend is in the build graph **by default since 1.4.0** (opt out with `SWIFT_ROS2_DISABLE_RCL=1`). **Linux:** opt-in with `SWIFT_ROS2_ENABLE_RCL=1`; links a system ROS 2 install via `ROS2_RCL_PREFIX` and picks the rmw at runtime from the transport type.
- **Internal wire fallback** (pure-Swift over `zenoh-pico` / CycloneDDS, no `rcl`) — the original all-platforms backend, an implementation detail since 2.0.0, and the golden-byte oracle for the CDR / wire codecs.

> **Apple RCL xcframeworks are Apple silicon (arm64) only.** `CRos2` / `CRos2Zenoh` ship arm64 slices for iOS, the iOS Simulator, Mac Catalyst, macOS and (`CRos2` only) visionOS, while the wire xcframeworks (`CZenohPico` / `CCycloneDDS`) carry arm64 and x86_64 for the iOS Simulator, macOS and Mac Catalyst. Since RCL is on by default (1.4.0), the default graph therefore fails to build for x86_64 (typically with undefined `_rcl_*` / `_rmw_*` symbols) on an Intel Mac, in an x86_64 or universal iOS Simulator build (for example the Release configuration with a `generic/platform=iOS Simulator` destination and no `ARCHS=arm64`), and in Mac Catalyst or macOS builds that include x86_64 (Release and Archive builds default to arm64 + x86_64). If the app need not run on Intel Macs or in x86_64 simulators, build arm64 only and keep RCL: `ARCHS=arm64` (or `EXCLUDED_ARCHS[sdk=macosx*]=x86_64` for Mac Catalyst / macOS archives; `ONLY_ACTIVE_ARCH=YES` for simulator builds on an Apple silicon Mac). For an Intel Mac, or any build that must include x86_64, set `SWIFT_ROS2_DISABLE_RCL=1` instead (wire-only graph, which keeps x86_64). Arm64 Debug builds with "Build Active Architecture Only" are unaffected.

**The wire clients are not public API** (removed in 2.0.0): `ZenohClient` / `DDSClient` and the `SwiftROS2Zenoh` / `SwiftROS2DDS` products are gone — use `ROS2Context`. The wire runtime remains the internal fallback where RCL is not available; since it is internal, retiring it on a platform in a later minor release is non-breaking.

`ROS2Context` picks the backend per context from the `TransportConfig` type and the build graph (`makeDefaultSession(for:)` in [`Context.swift`](Sources/SwiftROS2/Context.swift)):

| Build graph | `.zenoh(locator:)` | `.ddsMulticast` / `.ddsUnicast` | `.rcl` / `.rclUnicast` |
|---|---|---|---|
| Apple, default (RCL on, `cyclonedds` rmw) | wire (zenoh-pico) | wire (CycloneDDS) | RCL + `rmw_cyclonedds_cpp` |
| Apple, `SWIFT_ROS2_RCL_RMW=zenoh` | RCL + `rmw_zenoh_cpp` | wire (CycloneDDS) | throws |
| Apple, `SWIFT_ROS2_DISABLE_RCL=1` | wire | wire | throws |
| Linux, default | wire | wire (system CycloneDDS) | throws |
| Linux, `SWIFT_ROS2_ENABLE_RCL=1` | RCL + `rmw_zenoh_cpp` | RCL + `rmw_cyclonedds_cpp` | RCL + `rmw_cyclonedds_cpp` |
| Windows | wire | wire with `CYCLONEDDS_DIR`, otherwise throws | throws |
| Android | wire | throws | throws |

"throws" = `ROS2Context(transport:)` throws `TransportError.unsupportedFeature`. On the default Apple graph only `.rcl` / `.rclUnicast` reach RCL.

The umbrella API is **unchanged** — most consumers need no change:

```swift
let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/192.168.1.85:7447"))
```

Code that built the 1.x wire clients only to hand them to `ROS2Context` drops the explicit construction; standalone uses (raw key-expression puts, wire-level subscribers) move to `node.createPublisher` / `node.createSubscription`. `SwiftROS2Wire` stays public; the CDR codec (`SwiftROS2CDR`) and the message types live in swift-ros2-rosidl. Full recipes in [`MIGRATION.md`](MIGRATION.md).

> **Per-variant nuance.** In the Apple zenoh-rmw RCL variant (`SWIFT_ROS2_RCL_RMW=zenoh`) the zenoh wire family is *physically absent* (zenoh-pico and the bundled zenoh-c export the same C symbols and cannot co-link), so `.zenoh(locator:)` resolves to `rcl` + `rmw_zenoh_cpp` there; that variant ships no visionOS slice (visionOS builds use the default graph). On Linux RCL builds both backends stay linked (rmw is a dlopen'd plugin), but every transport type resolves to RCL, and the rmw is process-global — one process serves one rmw at a time. **Windows RCL is deferred** — to be re-evaluated against Lyrical's Windows 11 Tier 1 binaries. **Android RCL** (full-`rcl` NDK cross-build) remains unsolved.

> **CycloneDDS per graph.** In the default Apple graph (cyclonedds RCL variant) the wire `.dds` transport runs on the CycloneDDS inside `CRos2` (11.0.1, type and topic discovery on, with the iOS Wi-Fi padding patch), so a binary carries one CycloneDDS. Wire-only graphs (`SWIFT_ROS2_DISABLE_RCL=1`) and the zenoh variant keep the bundled `CCycloneDDS` (the 0.10.5 fork).

### RCL backend: supported types and hosts

**Supported types.** The RCL backend hands messages to `rcl` through the type support of the ROS packages bundled in `CRos2` / `CRos2Zenoh` (and, on Linux, the system ROS 2 install), looked up by type name in generated registries under [`Sources/CRclBridge/Generated/`](Sources/CRclBridge/Generated) (`Scripts/regen-rcl-registry.sh` produces them). A type is usable over RCL only if its name is in the registry, which covers:

- Messages: `std_msgs` `Bool`, `Empty`, `Float64`, `Header`, `Int32`, `String`; `builtin_interfaces/Time`; `geometry_msgs` `Accel`, `Point`, `Point32`, `Pose`, `PoseStamped`, `Quaternion`, `Transform`, `TransformStamped`, `Twist`, `TwistStamped`, `Vector3`, `Vector3Stamped`, `Wrench`; `tf2_msgs/TFMessage`; `example_interfaces/String`; 27 `sensor_msgs` types (`Imu`, `Image`, `CompressedImage`, `CameraInfo`, `PointCloud2`, `PointField`, `NavSatFix`, `LaserScan`, `JointState`, `Joy`, `BatteryState`, `Range`, `Temperature`, and the rest of the list in the generated registry); the `rcl_interfaces` parameter messages; `action_msgs/GoalStatusArray`; and two consumer packages, `audio_common_msgs/AudioData` and `point_cloud_interfaces/CompressedPointCloud2`.
- Services: the six `rcl_interfaces` parameter services, `std_srvs` `Empty` / `SetBool` / `Trigger`, `example_interfaces` `AddTwoInts` / `Trigger`, `sensor_msgs/SetCameraInfo` and `action_msgs/CancelGoal`.
- Actions: `example_interfaces/Fibonacci` only.

Anything else, such as `nav_msgs/Odometry`, `std_msgs/Int8` or your own generated type, has no bundled type support:

- On `rmw_zenoh_cpp` (the Apple zenoh variant, and `.zenoh` on Linux RCL builds) creating the publisher or subscription throws `TransportError.unsupportedFeature` ("type … has no bundled typesupport"). Use the wire `.zenoh` transport for such types (the default Apple graph, `SWIFT_ROS2_DISABLE_RCL=1`, or Linux without `SWIFT_ROS2_ENABLE_RCL=1`), or bundle the type's package and add the type to the registry (`Scripts/build-ros2-xcframework.sh`, `Scripts/regen-rcl-registry.sh`).
- On `rmw_cyclonedds_cpp` publishers and subscriptions fall back to a raw-CDR writer or reader on a sibling CycloneDDS participant. That fallback is CycloneDDS-only and bypasses `rmw`. Services and actions have no fallback: an unlisted service or action type fails with `unsupported service type` / `unsupported action type`.

**Supported hosts.** The RCL backends are built from ROS 2 Lyrical and are tested against Jazzy and Lyrical hosts (see "Interop" below). Humble hosts are not supported over RCL: a Humble `rmw_zenoh_cpp` host receives no data, and a Humble `rmw_cyclonedds_cpp` host logs deserialization warnings. For a Humble host use the wire transports (wire `.zenoh(locator:)` with `distro: .humble`, and `.ddsUnicast(peers:)` / `.ddsMulticast(domainId:)`), which are what the default Apple graph and any build without RCL select; keep the build out of the zenoh variant (`SWIFT_ROS2_RCL_RMW=zenoh`) and do not set `SWIFT_ROS2_ENABLE_RCL=1` on Linux, since both route those transports to RCL.

### Interop (Apple RCL on Lyrical)

Tested Mac ↔ Ubuntu host, `ROS_DOMAIN_ID=123`, on the 2.2.0 release-candidate xcframeworks (`CRos2` / `CRos2Zenoh` from the release dry run, `SWIFT_ROS2_RCL_LOCAL=1`), driving the `Sources/Examples` binaries against `ros2` CLI tools and `rclpy` servers on the host. The zenoh columns use the zenoh RCL variant (`SWIFT_ROS2_RCL_RMW=zenoh`); the four DDS columns (`.rcl` and wire `.dds`) use the default cyclonedds graph, where `.rcl` is the native RCL backend and `.dds` is the wire transport on the CycloneDDS inside `CRos2` (11.0.1). The wire `.dds` cells marked FAIL ¹ are pre-existing, not caused by this change (see footnote 1).

| Check | zenoh × Jazzy | zenoh × Lyrical (apt 0.10.6 / zenohd 1.10.1) | cdds `.rcl` × Jazzy | cdds `.rcl` × Lyrical | wire `.dds` × Jazzy | wire `.dds` × Lyrical |
|---|---|---|---|---|---|---|
| pub (Mac → host) | PASS | PASS / PASS | PASS | PASS | PASS | PASS |
| sub (host → Mac) | PASS | PASS / PASS | PASS | PASS | PASS | PASS |
| service, Mac server | PASS | PASS / PASS | PASS | PASS | PASS | PASS |
| service, Mac client | PASS | PASS / PASS | PASS | PASS | FAIL ¹ | FAIL ¹ |
| action, Mac server | PASS | PASS / PASS | PASS | PASS | PASS | PASS |
| action, Mac client | PASS | PASS / PASS | PASS | PASS | FAIL ¹ | FAIL ¹ |
| parameters (`ros2 param list` / `set` / `get`) | PASS | PASS / PASS | PASS | PASS | FAIL ¹ | FAIL ¹ |
| graph (`ros2 node list`, `topic info -v` RIHS01 hash) | PASS | PASS / PASS | PASS | PASS | FAIL ¹ | FAIL ¹ |
| unicast pub / sub (`rcl-unicast` / `dds-unicast`) | n/a | n/a | PASS / PASS | PASS / PASS | PASS / PASS | PASS / PASS |
| burst soak, 500 Hz IMU, 60 s, `received` / `published` | PASS (99.99 %) | PASS (99.87 %) / PASS, 2 of 3 runs ≥ 99 % (98.36, 99.98, 99.88 %) ² | PASS (99.99 %) | PASS (99.99 %) | PASS (99.99 %) | PASS (99.99 %) |

¹ These cells fail identically on the released 2.1.0 (wire-only, CycloneDDS 0.10.5) in this setup (no multicast between the two Wi-Fi hosts, the Mac as a host-side unicast peer), against both the Jazzy and the Lyrical host, so they are not caused by this change. They conflict with the 2.0.0 claim that DDS services, actions and `ros2 param` interoperate with `rmw_cyclonedds_cpp` (#115) and are under investigation (#200). Observed: the wire path publishes no `ros_discovery_info`, so host graph and parameter tools cannot find its nodes (`ros2 node list` is empty, `ros2 param` says `Node not found`, `topic info -v` reports an unknown node name; the graph cell does report the RIHS01 type hash correctly, only the node name is missing), and the Mac-side wire service and action clients time out without a reply from an `rmw_cyclonedds_cpp` server (`Service call failed: timeout`, `ActionError.acceptanceTimedOut`); the cause of the missing reply is not root-caused. The `.rcl` cells for the same checks pass.

² Soak rule: a cell passes when `received` is at least 99 % of `published` (30000); where a run falls under 99 %, the cell is rated on 3 runs and passes with 2 of 3. Against zenohd 1.10.1 the first run lost about one second of echoes mid-run (`recv_per_s=451` in one window) and reached 98.36 %; the reruns delivered 29995 and 29963 of 30000.

Qualifiers:

- **Host NIC pin and Mac as peer.** The host's CycloneDDS was pinned to its live Wi-Fi NIC through `CYCLONEDDS_URI` (without the pin it picks a down interface). The test LAN, two Wi-Fi clients, did not forward `239.255.0.1` multicast between the Mac and the host, so every DDS cell ran with the Mac added as an explicit host-side peer (`<Peer address="<mac-ip>:38150"/>`, `SPDPInterval` 1 s) while the Mac used its default arms (`rcl`, `dds`); pure-multicast discovery failed on this LAN, so multicast discovery between the two machines could not be demonstrated here. The host-side `SPDPInterval` of 1 s was set after a first pass at the default interval (the first `.rcl` × Lyrical service-client attempt then failed with `Service did not appear`); all reported cells use the final configuration. The unicast cells (`rcl-unicast`, `dds-unicast`) additionally ran with host multicast disabled and exercise the generated discovery XML on CycloneDDS 11.0.1.
- **Jazzy host.** One native Jazzy sync (June 2026 packages): `rcl` 9.2.11, `rmw_cyclonedds_cpp` 2.2.3 with CycloneDDS 0.10.5, `rmw_zenoh_cpp` 0.2.9 with its own `rmw_zenohd` as the router. Older Jazzy syncs are not covered. The Jazzy soak relay is an `rclpy` pass-through (`topic_tools` is not installed there).
- **Lyrical host.** The `ros:lyrical` apt packages: `rcl` 10.4.5, `rmw_cyclonedds_cpp` 4.1.5 with CycloneDDS 11.0.1, `rmw_zenoh_cpp` 0.10.6 with zenoh-c 1.8.0. apt still ships 0.10.6, not the 0.10.7 / Zenoh 1.10.1 that the Mac side pins, so the zenoh × Lyrical column ran twice: against the apt `rmw_zenohd` 0.10.6 (the Mac logged 14 `Unknown token` ERROR lines against this router, in one cell only (action, Mac server), verdict unaffected; none against zenohd 1.10.1 or the Jazzy router; the cause is not established) and against a standalone `zenohd` 1.10.1 (`--listen tcp/0.0.0.0:7447 --no-multicast-scouting`). zenoh × Jazzy used the host's `rmw_zenohd` 0.2.9. The Lyrical soak relay is `ros2 run topic_tools relay`.
- **Not covered.** Route (b), the raw-CDR path for types outside the marshal registry, is not run against a host (every example publishes a registry type); it stays covered by the in-process `crcl-nonbundled*` loopbacks, now on one CycloneDDS.

## API stability

2.0.0 opened the [SemVer](https://semver.org/spec/v2.0.0.html) contract that 1.0.0 inaugurated, and 3.x continues it: no minor or patch release breaks the public API; breaking changes require a major bump. The frozen 3.x surface covers the products of this package: `ROS2Context`, `ROS2Node`, `ROS2Publisher`, `ROS2Subscription`, `ROS2Service`, `ROS2Client`, `ROS2ActionServer`, `ROS2ActionClient`, `QoSProfile`, `TransportConfig`, and the `SwiftROS2Wire` / `SwiftROS2Transport` types. Message types follow [swift-ros2-common-interfaces](https://github.com/swift-ros2/swift-ros2-common-interfaces)' own 1.x contract, and the CDR codec and protocols follow [swift-ros2-rosidl](https://github.com/swift-ros2/swift-ros2-rosidl)'s. Retiring the internal wire fallback per platform in minors is non-breaking. See [`MIGRATION.md`](MIGRATION.md) for the 2.x → 3.0 split, the 1.x → 2.0 wire-client removal and the internal-plumbing demotions made at the 1.0 cut. New ROS 2 distributions are added to `ROS2Distro` in minor releases (the yearly May release), so code that switches over `ROS2Distro` must include a `default` branch.

## Features

- **Dual transport, two backends, one API.** The `TransportConfig` type picks the transport and the build graph picks the backend behind it (see the routing table under [Backends](#backends-rcl-with-an-internal-wire-fallback)). Switch transports with a single `TransportConfig` change.
- **No mandatory `rcl` toolchain.** Apple downloads prebuilt xcframeworks (including the RCL variants); Linux uses a system ROS 2 install for RCL; the wire path needs no ROS 2 install at all (Windows resolves CycloneDDS via `vcpkg`; Android is Zenoh-only).
- **Swift-native API.** `async`/`await` everywhere, `AsyncStream` subscriptions, `Sendable`, structured concurrency, no opaque pointer juggling above the FFI seam.
- **Multi-distro.** Humble, Jazzy, Kilted, Lyrical, Rolling — select via `ROS2Distro` (Zenoh defaults to Jazzy). Schema differences (e.g. `sensor_msgs/Range.variance`, added after Humble) are gated automatically via `isLegacySchema`.
- **Standard messages in their own package.** The `sensor_msgs`, `geometry_msgs`, `std_msgs`, `tf2_msgs`, … Swift types live in [swift-ros2-common-interfaces](https://github.com/swift-ros2/swift-ros2-common-interfaces), on the pure-Swift XCDR v1 encoder + decoder from [swift-ros2-rosidl](https://github.com/swift-ros2/swift-ros2-rosidl).
- **Services & Actions** — `rclcpp` / `rclpy`-shaped `ROS2Service` / `ROS2Client` and typed `ROS2ActionServer<H>` / `ROS2ActionClient<A>` (goal handles, feedback `AsyncStream`, cancellation) over both transports, all distros.
- **Parameters** — every `ROS2Node` declares typed parameters with descriptors / ranges, auto-registers the six standard `rcl_interfaces` services, and publishes `/parameter_events`; interoperates with `ros2 param`.
- **Code generation from IDL** lives in swift-ros2-rosidl: the `swift-ros2-gen` CLI and the SwiftPM build plugin emit `ROS2Message` / `ROS2ServiceType` / `ROS2Action` conformances from `.msg` / `.srv` / `.action`.

## Platforms

| Platform     | Minimum target                          | Integration path                                                | Transports   |
|--------------|-----------------------------------------|-----------------------------------------------------------------|--------------|
| iOS / iPadOS | 16.0                                    | `binaryTarget` xcframework                                       | Zenoh + DDS  |
| macOS        | 13.0                                    | `binaryTarget` xcframework                                       | Zenoh + DDS  |
| Mac Catalyst | 16.0                                    | `binaryTarget` xcframework                                       | Zenoh + DDS  |
| visionOS     | 1.0                                     | `binaryTarget` xcframework                                       | Zenoh + DDS  |
| Linux        | Ubuntu 22.04 / 24.04 (x86_64, aarch64)  | `zenoh-pico` source build + `pkg-config` for DDS                | Zenoh + DDS  |
| Windows      | Windows 10 / 11 (x86_64)                | `zenoh-pico` source build (Winsock) + `vcpkg` for DDS           | Zenoh + DDS  |
| Android      | API 28+ (arm64-v8a, x86_64)             | `zenoh-pico` source build (Bionic, unix backend)                | Zenoh only (umbrella API) |

Swift 5.9+ on Apple; the CI matrix is unified on Swift 6.3.1 across macOS (Xcode 26.4.1), Linux, Windows, and Android; the RCL Lyrical lane uses Swift 6.4.0, the first toolchain built for Ubuntu 26.04. By worldwide market share ([Statcounter, March 2026](https://gs.statcounter.com/os-market-share)) swift-ros2 covers **≈99.7%** of the mobile market and **≈90.7%** of identifiable device share — nearly every consumer device you might attach to a ROS 2 graph. Non-host Apple slices are built end-to-end by [`release-xcframework.yml`](.github/workflows/release-xcframework.yml) at tag time; per-push iOS / visionOS / Mac Catalyst runtime validation comes from Conduit rather than CI. Architecture: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Installation

### Apple (recommended)

```swift
// swift-tools-version: 5.9
// Package.swift
import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [.macOS(.v13), .iOS(.v16)],   // required for a macOS package
    dependencies: [
        .package(url: "https://github.com/swift-ros2/swift-ros2.git", from: "3.0.0"),
        .package(url: "https://github.com/swift-ros2/swift-ros2-common-interfaces.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(name: "YourApp", dependencies: [
            .product(name: "SwiftROS2", package: "swift-ros2"),
            .product(name: "CommonInterfaces", package: "swift-ros2-common-interfaces"),
        ]),
    ]
)
```

`swift build` downloads the pinned xcframeworks in seconds — no CMake, no local bootstrap. Since 1.4.0 that includes the RCL xcframework (`CRos2`); set `SWIFT_ROS2_DISABLE_RCL=1` in the environment that resolves packages (for Xcode, the environment Xcode itself runs in) to keep a wire-only graph (needed on an Intel Mac or for any build that must include x86_64; arm64-only builds keep RCL: the RCL xcframeworks are arm64-only, see [Backends](#backends-rcl-with-an-internal-wire-fallback)). `import SwiftROS2` exposes `ROS2Context` / `ROS2Node` / `ROS2Publisher` / `ROS2Subscription` and transitively links the backends; `SwiftROS2` is the product to depend on. (The URL pin points at the assets of the latest release that changed them, bumped in a PR after that tag; 2.3.1, 2.3.2 and 3.0 change only source-built code, so they keep the 2.3.0 assets. Pinning `from: "X.Y.Z"` resolves to the X.Y.Z commit; tracking `main` always picks up the latest pinned binaries.)

A package without `platforms:` builds for SwiftPM's default deployment target (macOS 12 with current toolchains), below what swift-ros2 and swift-ros2-common-interfaces require (macOS 13, iOS 16), so a new macOS command-line package that omits it stops with `The package product 'SwiftROS2-product' requires minimum platform version 13.0 for the macOS platform, but this target supports 12.0`. An Xcode app target gets its deployment target from the project instead; set it to iOS 16 / macOS 13 or later.

The binary xcframeworks (`CZenohPico`, `CCycloneDDS` and, unless `SWIFT_ROS2_DISABLE_RCL=1`, `CRos2`) are downloaded from the GitHub release the first time the package is resolved, in `swift build` or in Xcode's "Resolve Package Versions", so that first resolve needs network access to `github.com` and a cold CI runner pays the download once.

**iOS and iPadOS: local network permission.** Both LAN transports talk to hosts on the local network, and since iOS 14 the system asks the user for permission before an app does that. Add `NSLocalNetworkUsageDescription` to the app's `Info.plist` with a sentence that says why (for example, "Connects to your ROS 2 host to publish and subscribe to topics."). Without it the prompt never appears and connections to the Zenoh router or the DDS peers fail. `NSBonjourServices` lists the Bonjour service types an app browses or advertises (Conduit declares `_zenoh._tcp` and `_ros._tcp`); swift-ros2 itself discovers DDS participants with CycloneDDS's own SPDP traffic, not Bonjour, so the key only matters if your app also uses Bonjour. DDS multicast discovery is multicast traffic, which Apple additionally gates behind the Multicast Networking entitlement (`com.apple.developer.networking.multicast`, granted by Apple on request); `.ddsUnicast(peers:)` avoids that requirement. See Apple's [Local Network Privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) technote for the details.

### Linux

```bash
sudo apt install ros-jazzy-cyclonedds        # or ros-humble / ros-lyrical / ros-rolling
git clone --recursive https://github.com/swift-ros2/swift-ros2.git && cd swift-ros2
bash Scripts/build-linux-deps.sh             # verifies pkg-config finds CycloneDDS

# Re-export in the current shell — build-linux-deps.sh sets these only in its subprocess.
source /opt/ros/jazzy/setup.bash
export PKG_CONFIG_PATH=/opt/ros/jazzy/lib/$(uname -m)-linux-gnu/pkgconfig:$PKG_CONFIG_PATH

swift build
swift test                                    # tests that need a router or a ROS 2 host skip unless their environment variable is set
```

#### Using the package from your own project

A project that depends on swift-ros2 compiles the same C sources as this repository, so it needs the same system setup. Without it `swift build` stops with `fatal error: 'dds/dds.h' file not found` in `CDDSBridge` (checked on `swift:6.3.1-noble`, which has `pkg-config` but no CycloneDDS): the `CCycloneDDS` system library gets its include and library paths from `pkg-config` (package name `CycloneDDS`) and nothing else.

1. **Swift.** Swift 5.9 is the manifest's minimum (`swift-tools-version: 5.9`); CI and the Linux walkthrough use Swift 6.3.1 on Ubuntu 22.04 and 24.04 (x86_64 and aarch64), so prefer 6.3.x.
2. **Build tools.** `pkg-config` and `git` (the `swift` Docker images have both). SwiftPM clones the `vendor/zenoh-pico` and `vendor/cyclonedds` submodules when it resolves the package and compiles zenoh-pico itself, so no CMake step is needed.
3. **CycloneDDS development files and `CycloneDDS.pc`**, from one of:
   - **Ubuntu 24.04:** `sudo apt install cyclonedds-dev` (CycloneDDS 0.10.4). It puts the headers, `libddsc` and `CycloneDDS.pc` on the default paths, so nothing else is needed to build and run.
   - **ROS 2 apt repository:** `sudo apt install ros-<distro>-cyclonedds` (`humble`, `jazzy`, `kilted`, `lyrical`, `rolling`; CycloneDDS 0.10.5 on Jazzy; CI uses this) after [adding the ROS 2 apt source](https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html#setup-sources). It installs under `/opt/ros/<distro>`, outside the default search paths, so set `PKG_CONFIG_PATH` for the build and make `libddsc.so.0` loadable for the run:

     ```bash
     export PKG_CONFIG_PATH=/opt/ros/jazzy/lib/$(uname -m)-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
     pkg-config --exists CycloneDDS && echo ok     # must print ok before swift build
     swift build
     export LD_LIBRARY_PATH=/opt/ros/jazzy/lib/$(uname -m)-linux-gnu:$LD_LIBRARY_PATH   # or: source /opt/ros/jazzy/setup.bash
     ```

   - A [CycloneDDS](https://github.com/eclipse-cyclonedds/cyclonedds) 0.10.x built from source, with its `pkgconfig` directory on `PKG_CONFIG_PATH`.

   Without the `PKG_CONFIG_PATH` step the ROS package fails with the same `'dds/dds.h' file not found`, and without the `LD_LIBRARY_PATH` step the built executable stops with `error while loading shared libraries: libddsc.so.0`.

Declare the same dependencies as on Apple; a `platforms:` array is only needed for the Apple platforms and is harmless on Linux. The CycloneDDS development files are needed even if you only use Zenoh, because the DDS family is part of the Linux build graph.

### Windows

Both transports. Zenoh builds from source with no extra setup; DDS resolves CycloneDDS through [vcpkg](https://vcpkg.io). Requires Swift 6.3.1. Without `CYCLONEDDS_DIR`, the manifest stays Zenoh-only.

```powershell
vcpkg install cyclonedds:x64-windows
$env:CYCLONEDDS_DIR = "$env:VCPKG_ROOT\installed\x64-windows"
$env:Path = "$env:CYCLONEDDS_DIR\bin;$env:Path"   # so ddsc.dll resolves at runtime
```

Then add the same `.package(url:)` dependency as Apple. `swift build` threads `-I<dir>/include` + `-L<dir>/lib` into CDDSBridge from `CYCLONEDDS_DIR` — no `setup.bash` / `PKG_CONFIG_PATH` step.

### Android (cross-compile from macOS or Linux)

Install the Swift 6.3.1 Android SDK from [swift.org/install/android](https://www.swift.org/install/android/), install Android NDK ≥ r27, then run the bundled `setup-android-sdk.sh` once to symlink the NDK sysroot into place (see [swift.org](https://www.swift.org/install/android/) for the exact incantation).

```bash
swift sdk install <android-sdk-url> --checksum <sha>
SWIFT_ROS2_TARGET_OS=android swift build --swift-sdk aarch64-unknown-linux-android28
# or x86_64-unknown-linux-android28 for emulator targets
```

`SWIFT_ROS2_TARGET_OS=android` is **required** for any cross-compile — SwiftPM evaluates manifest-scope `#if os(...)` against the host, so without it a Linux host pulls in the un-buildable DDS path and a macOS host never source-builds `zenoh-pico`. The value is allow-list-validated (`{android, apple, linux, windows}`); typos fail the manifest compile. The `SwiftROS2` umbrella builds on Android (Zenoh-only): `.dds` transports throw `TransportError.unsupportedFeature`.

## Packages

swift-ros2 is split into three packages in the [`swift-ros2`](https://github.com/swift-ros2) organization:

| Package | Role |
|---|---|
| [swift-ros2](https://github.com/swift-ros2/swift-ros2) (this repository) | The runtime: transports (Zenoh, DDS, RCL), `ROS2Context` / `ROS2Node`, services, actions and parameters. |
| [swift-ros2-rosidl](https://github.com/swift-ros2/swift-ros2-rosidl) | The XCDR v1 codec (`SwiftROS2CDR`), the `ROS2Message` protocols and `ROS2Distro` (`SwiftROS2Messages`), the runtime interface types (`BuiltinInterfaces`, `UniqueIdentifierMsgs`, `ActionMsgs`, `RclInterfaces`), and the IDL code generator (`swift-ros2-gen`, `SwiftROS2GenPlugin`). |
| [swift-ros2-common-interfaces](https://github.com/swift-ros2/swift-ros2-common-interfaces) | The generated standard message packages (`sensor_msgs`, `geometry_msgs`, `std_msgs`, …), one library per ROS package. |

swift-ros2 depends on swift-ros2-rosidl only; it never depends on swift-ros2-common-interfaces, so you add that package for the message types you use:

```swift
.package(url: "https://github.com/swift-ros2/swift-ros2.git", from: "3.0.0"),
.package(url: "https://github.com/swift-ros2/swift-ros2-common-interfaces.git", from: "1.0.0"),
// target:
.product(name: "SwiftROS2", package: "swift-ros2"),
.product(name: "CommonInterfaces", package: "swift-ros2-common-interfaces"),
```

```swift
import SwiftROS2
import CommonInterfaces   // every standard package; or import single modules such as `SensorMsgs`, `StdMsgs`, `GeometryMsgs`
```

`import SwiftROS2` re-exports the swift-ros2-rosidl runtime modules (CDR, the protocols, `ROS2Distro`), so a project that only needs the runtime needs one import. The targets inside this package are described in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

`CZenohPico` / `CCycloneDDS` are link-only C targets, consumed at the C level by `CZenohBridge` / `CDDSBridge` and **never `import`ed from Swift** (a CI lint guards against it).

### Code generation

Code generation moved to swift-ros2-rosidl; see its [README](https://github.com/swift-ros2/swift-ros2-rosidl#readme) for `swift-ros2-gen`, the build plugin and the hash oracle.

## Versioning

Tags follow Apple-ecosystem bare semver (no `v` prefix): `0.2.0`, `1.0.0-rc.1`, … The [release workflow](.github/workflows/release-xcframework.yml) fires on any tag matching `[0-9]*.[0-9]*.[0-9]*` (optionally `-qualifier`), builds both xcframeworks for all six Apple slices, and attaches them + `.checksum` files to the GitHub release. The pin URL + checksums are bumped in a follow-up PR (GitHub re-zips on upload, so server-side checksums must be re-computed with `swift package compute-checksum`).

## Release history

Each release has a [GitHub release](https://github.com/swift-ros2/swift-ros2/releases) with full notes; headlines below.

| Tag        | Date       | Headline                                                                                              |
|------------|------------|-------------------------------------------------------------------------------------------------------|
| **2.3.2**  | 2026-10-12 | **Teardown off the cooperative pool.** `ROS2Context.shutdown()`, `ROS2Node.destroy()` and `ROS2ParameterClient.close()` run their blocking closes on a per-context serial queue, so teardowns during a network stall no longer starve Swift's cooperative thread pool; the teardowns of one context run one at a time. Patch; the binary targets stay on the 2.3.0 assets. |
| 2.3.1      | 2026-10-11 | **Wire Zenoh after a router loss.** A session that lost its router now reports unknown matching and `isConnected == false`, `publish` throws the recoverable `TransportError.sessionUnhealthy`, and closing such a session after the loss is detected no longer crashes (a crash present in 2.3.0). Patch; the binary targets stay on the 2.3.0 assets. |
| 2.3.0      | 2026-10-10 | **Matched subscriptions, TRANSIENT_LOCAL on wire Zenoh, zenoh-pico 1.7.1.** `ROS2Publisher.hasMatchedSubscriptions` and `onMatchedSubscriptionsChanged(_:)` report whether anyone listens (Zenoh, DDS and RCL); TRANSIENT_LOCAL is served on wire Zenoh through zenoh-pico's advanced publisher, so late-joining rmw_zenoh subscribers get the cache; the vendored zenoh-pico moves to 1.7.1. Additive. |
| 2.2.0      | 2026-10-09 | **Apple RCL on ROS 2 Lyrical.** `CRos2` / `CRos2Zenoh` (renamed) are built from Lyrical and interoperate with Jazzy and Lyrical hosts; the default graph links one CycloneDDS (11.0.1). |
| 2.1.0      | 2026-10-08 | **ROS 2 Lyrical Luth.** `ROS2Distro.lyrical` joins the modern wire group (same key expressions and type hashes as Jazzy); the hash oracle gains a required Lyrical lane and a weekly run. New distributions ship in minors by policy. |
| 2.0.0      | 2026-09-22 | **Wire clients leave the public API.** `ZenohClient` / `DDSClient` and their products removed; DDS service/action interop with `rmw_cyclonedds_cpp` fixed (#115); `ActionGoalHandle.result()` without a timeout no longer traps (#190). Wire runtime stays as the internal fallback. |
| 1.4.0      | 2026-09-21 | **Bridge to 2.0.** Umbrella API on Android / DDS-less Windows; first tag carrying RCL-default-on + the wire-client deprecation; fixes #116, #162, #176. |
| 1.3.0      | 2026-07-13 | **RCL everywhere it can reach.** Native `rcl` + `rmw_zenoh_cpp` / `rmw_cyclonedds_cpp` backend, opt-in via `SWIFT_ROS2_ENABLE_RCL=1`, on Apple (prebuilt xcframeworks) and Linux (system ROS 2 install). Parity matrix across latency / correctness / resource axes for both rmws. Additive except the new `TransportType.rcl` case, which breaks exhaustive `switch`es (#119–#172). |
| 1.2.0      | 2026-06-06 | **Source-timestamp publish overload** — additive `publish(_:timestamp:sequenceNumber:)` (#117). |
| 1.1.0      | 2026-05-06 | **Parameter API** — typed declares, the six `rcl_interfaces` services, `/parameter_events`, `ROS2ParameterClient` (#102–#107). |
| 1.0.0      | 2026-05-05 | **API stability promise (1.x SemVer freeze)** — plumbing types pulled out of the public surface; end-user types unchanged. |
| 0.9.0      | 2026-05-04 | **`swift-ros2-gen`** — IDL → Swift code generator (CLI + SwiftPM plugin) + `verify-hash-oracle` CI. |
| 0.8.0      | 2026-05-03 | **Actions + DDS on Windows** — typed `ROS2ActionServer` / `ROS2ActionClient`; CycloneDDS on Windows via vcpkg. |
| 0.7.0      | 2026-05-01 | **Services** — typed `ROS2Service` / `ROS2Client` over Zenoh and DDS. |
| 0.6.0      | 2026-04-24 | **Android** — arm64-v8a + x86_64 via the Swift Android SDK (Zenoh only). |
| 0.5.0      | 2026-04-24 | **Windows x86_64** — three-arm `Package.swift` split, `zenoh-pico` source build (Zenoh only). |
| 0.4.0      | 2026-04-20 | **DDS subscriber** — `CDDSBridge` fragchain reader; `swift run listener dds`. |
| 0.3.0      | 2026-04-19 | **API rename (breaking)** — drop `Default` prefix from `ZenohClient` / `DDSClient`; Linux arm64 + Rolling + Humble CI. |
| 0.2.0      | 2026-04-18 | **Initial public release** — Publisher + Subscriber, XCDR v1 codec, Jazzy + Humble wire, dual transport. |

## Roadmap

Concrete deliverables, not aspirational vapor.

**Near-term (additive, 3.x):** TF / TF2 runtime layer (`TransformBroadcaster`, `Buffer` + `TransformListener`, mirroring `tf2_ros`); logging / `/rosout` (`Logger` on `ROS2Node`, bridging `os.Logger`).

**Medium-term:** DDS on Android (blocked on `ddsrt`'s CMake-time header generation under the NDK; likely a prebuilt `.artifactbundle`); XCDR2 wire format; `LifecycleNode` (nine-state machine + `lifecycle_msgs`); composition / intra-process short-circuit; discovery control (`ROS_AUTOMATIC_DISCOVERY_RANGE`, `ROS_STATIC_PEERS`).

**Stretch:** Linux static `.artifactbundle`; `watchOS` / `tvOS` slices; OpenXR-on-Android for Quest / Pico; rosbag2 (`mcap`) read/write; DDS Security; action-server fan-out; a minimal `xacro` / URDF parser.

## Contributing

PRs welcome. The wire fixtures in [`Tests/SwiftROS2WireTests/`](Tests/SwiftROS2WireTests/) are the canonical guardrails (the golden CDR tests live in swift-ros2-rosidl) — keep them green. [`Tests/SwiftROS2IntegrationTests/`](Tests/SwiftROS2IntegrationTests/) holds the tests that need a live peer, and each skips unless its environment variable is set: `ZENOH_ROUTER=tcp/<host>:7447` (a Zenoh router; CI starts a loopback `zenohd`), `ZENOH_TEST_ROUTER_CONTAINER=<name>` (additionally, the Docker container running that router, for the router-loss tests), and `LINUX_IP=<host>` (a ROS 2 host running the matching CLI subscriber or publisher; CI cannot run these). Some LAN tests also need an RCL build and `RCL_SVC_EXPECT_CALL=1`; see the header of each test file. Lint with `swift format lint --strict --configuration .swift-format Package.swift Sources Tests` before pushing — CI fails lint before any build matrix runs.

## License

Apache License 2.0. See [LICENSE](LICENSE).
