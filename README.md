# swift-ros2

[![Apple CI](https://img.shields.io/github/actions/workflow/status/youtalk/swift-ros2/ci.yml?branch=main&label=Apple)](https://github.com/youtalk/swift-ros2/actions/workflows/ci.yml)
[![Linux CI](https://img.shields.io/github/actions/workflow/status/youtalk/swift-ros2/ci.yml?branch=main&label=Linux)](https://github.com/youtalk/swift-ros2/actions/workflows/ci.yml)
[![Windows CI](https://img.shields.io/github/actions/workflow/status/youtalk/swift-ros2/ci.yml?branch=main&label=Windows)](https://github.com/youtalk/swift-ros2/actions/workflows/ci.yml)
[![Android CI](https://img.shields.io/github/actions/workflow/status/youtalk/swift-ros2/ci.yml?branch=main&label=Android)](https://github.com/youtalk/swift-ros2/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/youtalk/swift-ros2?label=release&sort=semver)](https://github.com/youtalk/swift-ros2/releases)
[![ROS 2](https://img.shields.io/badge/ROS%202-Humble%20%7C%20Jazzy%20%7C%20Kilted%20%7C%20Lyrical%20%7C%20Rolling-22314E.svg)](https://docs.ros.org)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![SPI Swift compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fyoutalk%2Fswift-ros2%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/youtalk/swift-ros2)
[![SPI platform compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fyoutalk%2Fswift-ros2%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/youtalk/swift-ros2)

Native Swift client library for ROS 2. Publish and subscribe to ROS 2 topics over **Zenoh** or **DDS** on every consumer device OS that runs Swift — no `rcl` cross-compile for you, no bridge. A single `.package(url:)` on Apple, `apt install ros-<distro>-cyclonedds` on Linux, a vanilla `swift build` on Windows / Android. The API is Swift-native (`async`/`await`, `AsyncStream`, `Sendable`) and round-trip compatible with `rmw_zenoh_cpp` / `rmw_cyclonedds_cpp`.

Shipping on the SemVer-stable **2.x** line (latest tag in the release badge). Extracted from [Conduit, powered by ROS](https://apps.apple.com/app/id6757171237) — used cumulatively by **10,000+ ROS developers** and a former **#4** in the App Store's Developer Tools category.

## Quick Start

```swift
import SwiftROS2

// Publish an IMU message over Zenoh.
let context = try await ROS2Context(
    transport: .zenoh(locator: "tcp/192.168.1.100:7447"), distro: .jazzy)
let node = try await context.createNode(name: "sensor_node", namespace: "/ios")
let pub = try await node.createPublisher(Imu.self, topic: "imu")
try pub.publish(Imu(
    header: Header.now(frameId: "imu_link"),
    linearAcceleration: Vector3(x: 0, y: 0, z: 9.81)))

// Same over DDS — identical Node / Publisher / Subscription API from here on.
let ddsContext = try await ROS2Context(transport: .ddsMulticast(domainId: 0))

// Subscribe.
let sub = try await node.createSubscription(Imu.self, topic: "imu")
for await msg in sub.messages { print("accel: \(msg.linearAcceleration)") }
```

### Services

`ROS2Service<S>` / `ROS2Client<S>` round-trip a typed request / response over either transport (Zenoh queryables or DDS rq/rr topics). Failures surface as `ServiceError` (`.timeout`, `.handlerFailed`, `.serviceUnavailable`, `.taskCancelled`, …).

```swift
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

**2.0.0 removes the wire clients from the public API; the wire runtime remains the internal fallback where RCL is not available and is retired per platform in 2.x minors, non-breaking.** `ZenohClient` / `DDSClient` and the `SwiftROS2Zenoh` / `SwiftROS2DDS` products are gone — use `ROS2Context`.

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

Code that built the 1.x wire clients only to hand them to `ROS2Context` drops the explicit construction; standalone uses (raw key-expression puts, wire-level subscribers) move to `node.createPublisher` / `node.createSubscription`. The CDR and wire codecs (`SwiftROS2CDR`, `SwiftROS2Wire`) stay public. Full recipes in [`MIGRATION.md`](MIGRATION.md).

> **Per-variant nuance.** In the Apple zenoh-rmw RCL variant (`SWIFT_ROS2_RCL_RMW=zenoh`) the zenoh wire family is *physically absent* (zenoh-pico and the bundled zenoh-c export the same C symbols and cannot co-link), so `.zenoh(locator:)` resolves to `rcl` + `rmw_zenoh_cpp` there; that variant ships no visionOS slice (visionOS builds use the default graph). On Linux RCL builds both backends stay linked (rmw is a dlopen'd plugin), but every transport type resolves to RCL, and the rmw is process-global — one process serves one rmw at a time. **Windows RCL is deferred** — to be re-evaluated against Lyrical's Windows 11 Tier 1 binaries. **Android RCL** (full-`rcl` NDK cross-build) remains unsolved.

> **CycloneDDS per graph.** In the default Apple graph (cyclonedds RCL variant) the wire `.dds` transport runs on the CycloneDDS inside `CRos2` (11.0.1, type and topic discovery on, with the iOS Wi-Fi padding patch), so a binary carries one CycloneDDS. Wire-only graphs (`SWIFT_ROS2_DISABLE_RCL=1`) and the zenoh variant keep the bundled `CCycloneDDS` (the 0.10.5 fork).

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

2.0.0 opens the 2.x line of the [SemVer](https://semver.org/spec/v2.0.0.html) contract that 1.0.0 inaugurated: no minor or patch release breaks the public API — breaking changes require a major bump. The frozen surface covers `ROS2Context`, `ROS2Node`, `ROS2Publisher`, `ROS2Subscription`, `ROS2Service`, `ROS2Client`, `ROS2ActionServer`, `ROS2ActionClient`, `QoSProfile`, `TransportConfig`, and every `ROS2Message` / `ROS2ServiceType` / `ROS2Action` type. Retiring the internal wire fallback per platform in 2.x minors is non-breaking. See [`MIGRATION.md`](MIGRATION.md) for the 1.x → 2.0 wire-client removal and the internal-plumbing demotions made at the 1.0 cut. New ROS 2 distributions are added to `ROS2Distro` in minor releases (the yearly May release), so code that switches over `ROS2Distro` must include a `default` branch.

## Features

- **Dual transport, two backends, one API.** The `TransportConfig` type picks the transport and the build graph picks the backend behind it (see the routing table under [Backends](#backends-rcl-with-an-internal-wire-fallback)). Switch transports with a single `TransportConfig` change.
- **No mandatory `rcl` toolchain.** Apple downloads prebuilt xcframeworks (including the RCL variants); Linux uses a system ROS 2 install for RCL; the wire path needs no ROS 2 install at all (Windows resolves CycloneDDS via `vcpkg`; Android is Zenoh-only).
- **Swift-native API.** `async`/`await` everywhere, `AsyncStream` subscriptions, `Sendable`, structured concurrency, no opaque pointer juggling above the FFI seam.
- **Multi-distro.** Humble, Jazzy, Kilted, Lyrical, Rolling — select via `ROS2Distro` (Zenoh defaults to Jazzy). Schema differences (e.g. `sensor_msgs/Range.variance`, added after Humble) are gated automatically via `isLegacySchema`.
- **23 built-in message types** across `sensor_msgs`, `geometry_msgs`, `std_msgs`, `audio_common_msgs`, `tf2_msgs`, on a pure-Swift XCDR v1 encoder + decoder.
- **Services & Actions** — `rclcpp` / `rclpy`-shaped `ROS2Service` / `ROS2Client` and typed `ROS2ActionServer<H>` / `ROS2ActionClient<A>` (goal handles, feedback `AsyncStream`, cancellation) over both transports, all distros.
- **Parameters** — every `ROS2Node` declares typed parameters with descriptors / ranges, auto-registers the six standard `rcl_interfaces` services, and publishes `/parameter_events`; interoperates with `ros2 param`.
- **Code generation from IDL.** `swift-ros2-gen` CLI + SwiftPM build plugin emit `ROS2Message` / `ROS2ServiceType` / `ROS2Action` conformances from `.msg` / `.srv` / `.action`, with multi-distro merging and a hash-oracle CI that catches drift against live ROS 2.

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
// Package.swift
dependencies: [
    .package(url: "https://github.com/youtalk/swift-ros2.git", from: "2.0.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "SwiftROS2", package: "swift-ros2"),
    ]),
]
```

`swift build` downloads the pinned xcframeworks in seconds — no CMake, no local bootstrap. Since 1.4.0 that includes the RCL xcframework (`CRos2`); set `SWIFT_ROS2_DISABLE_RCL=1` in the environment that resolves packages (for Xcode, the environment Xcode itself runs in) to keep a wire-only graph (needed on an Intel Mac or for any build that must include x86_64; arm64-only builds keep RCL: the RCL xcframeworks are arm64-only, see [Backends](#backends-rcl-with-an-internal-wire-fallback)). `import SwiftROS2` exposes `ROS2Context` / `ROS2Node` / `ROS2Publisher` / `ROS2Subscription` and transitively links the backends; `SwiftROS2` is the product to depend on. (The URL pin points at the assets of the latest release that changed them, bumped in a PR after that tag; 2.3.1 and 2.3.2 changed only source-built code, so they keep the 2.3.0 assets. Pinning `from: "X.Y.Z"` resolves to the X.Y.Z commit; tracking `main` always picks up the latest pinned binaries.)

### Linux

```bash
sudo apt install ros-jazzy-cyclonedds        # or ros-humble / ros-lyrical / ros-rolling
git clone --recursive https://github.com/youtalk/swift-ros2.git && cd swift-ros2
bash Scripts/build-linux-deps.sh             # verifies pkg-config finds CycloneDDS

# Re-export in the current shell — build-linux-deps.sh sets these only in its subprocess.
source /opt/ros/jazzy/setup.bash
export PKG_CONFIG_PATH=/opt/ros/jazzy/lib/$(uname -m)-linux-gnu/pkgconfig:$PKG_CONFIG_PATH

swift build
swift test                                    # 69 pass, 2 LINUX_IP-gated skips
```

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

## Module layout

```
import SwiftROS2          // public API — re-exports CDR / Messages / Transport / Wire
    ├── SwiftROS2CDR        — XCDR v1 encoder + decoder (pure Swift, no deps)
    ├── SwiftROS2Wire       — Zenoh / DDS wire codecs, ROS2Distro, TypeNameConverter
    ├── SwiftROS2Messages   — ROS2Message protocols + 23 built-in types
    └── SwiftROS2Transport  — TransportSession / TransportConfig / EntityManager / GIDManager

// Internal wire fallback — linked by SwiftROS2 where the build carries it, not
// products since 2.0.0 (nothing to import; reached through ROS2Context).
SwiftROS2Zenoh             — zenoh-pico wire client (FFI through CZenohBridge)
SwiftROS2DDS               — CycloneDDS wire client (FFI through CDDSBridge)
```

`CZenohPico` / `CCycloneDDS` are link-only C targets — consumed at the C level by `CZenohBridge` / `CDDSBridge` and **never `import`ed from Swift** (a CI lint guards against it). Inside the package, the C bridges are reached only through the internal `SwiftROS2Zenoh` / `SwiftROS2DDS` targets.

### Built-in message types

- **`sensor_msgs`** (13) — `BatteryState`, `CameraInfo`, `CompressedImage`, `FluidPressure`, `Illuminance`, `Image`, `Imu`, `Joy`, `MagneticField`, `NavSatFix`, `PointCloud2`, `Range`, `Temperature`
- **`geometry_msgs`** (3 publishable + utility types) — `PoseStamped`, `TransformStamped`, `TwistStamped`; sub-types `Vector3` / `Quaternion` / `Point` / `Pose` / `Twist` / `Transform`
- **`std_msgs`** (5) — `BoolMsg`, `EmptyMsg`, `Float64Msg`, `Int32Msg`, `StringMsg`; plus the universal `Header`
- **`audio_common_msgs`** (1) — `AudioData` · **`tf2_msgs`** (1) — `TFMessage`

## Code generation from IDL

`swift-ros2-gen` reads `.msg` / `.srv` / `.action` IDL and emits Swift `ROS2Message` / `ROS2ServiceType` / `ROS2Action` conformances — the recommended way to produce these since 0.9.0. Pass one `--input <pkg>=<path>@<distro>` per (package, distro) pair (every transitively-referenced package must appear so nested-type resolution succeeds); the generator merges multi-distro inputs into one Swift source that branches on `isLegacySchema`.

```bash
swift run swift-ros2-gen \
    --input "builtin_interfaces=vendor/rcl_interfaces-jazzy/builtin_interfaces@jazzy" \
    --input "std_msgs=vendor/common_interfaces-jazzy/std_msgs@jazzy" \
    --input "geometry_msgs=vendor/common_interfaces-jazzy/geometry_msgs@jazzy" \
    --input "sensor_msgs=vendor/common_interfaces-jazzy/sensor_msgs@jazzy" \
    --output Sources/MyMessages/Generated
```

For always-in-sync bindings, add the `SwiftROS2GenPlugin` build plugin to a target (single-package, single-distro, `.msg`-only; name the target snake_case — it becomes the ROS package segment). A worked setup is at [`Sources/Examples/PluginSmoke/`](Sources/Examples/PluginSmoke). The [`verify-hash-oracle`](.github/workflows/hash-oracle.yml) CI job diffs each generated `RIHS01_*` hash against an `osrf/ros:<distro>-desktop` image; reproduce locally with `--verify-hashes osrf/ros:jazzy-desktop`.

Custom Conduit-style types are hand-written under `Sources/Messages/` with the same `ROS2Message` conformance (`typeInfo` + `encode(to:)` + `init(from:)`).

## Versioning

Tags follow Apple-ecosystem bare semver (no `v` prefix): `0.2.0`, `1.0.0-rc.1`, … The [release workflow](.github/workflows/release-xcframework.yml) fires on any tag matching `[0-9]*.[0-9]*.[0-9]*` (optionally `-qualifier`), builds both xcframeworks for all six Apple slices, and attaches them + `.checksum` files to the GitHub release. The pin URL + checksums are bumped in a follow-up PR (GitHub re-zips on upload, so server-side checksums must be re-computed with `swift package compute-checksum`).

## Release history

Each release has a [GitHub release](https://github.com/youtalk/swift-ros2/releases) with full notes; headlines below.

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

**Near-term (additive, 2.x):** expanded message catalog (`nav_msgs`, `visualization_msgs`, `diagnostic_msgs`) via `swift-ros2-gen`; TF / TF2 runtime layer (`TransformBroadcaster`, `Buffer` + `TransformListener`, mirroring `tf2_ros`); logging / `/rosout` (`Logger` on `ROS2Node`, bridging `os.Logger`).

**Medium-term:** DDS on Android (blocked on `ddsrt`'s CMake-time header generation under the NDK; likely a prebuilt `.artifactbundle`); XCDR2 wire format; `LifecycleNode` (nine-state machine + `lifecycle_msgs`); composition / intra-process short-circuit; discovery control (`ROS_AUTOMATIC_DISCOVERY_RANGE`, `ROS_STATIC_PEERS`).

**Stretch:** Linux static `.artifactbundle`; `watchOS` / `tvOS` slices; OpenXR-on-Android for Quest / Pico; rosbag2 (`mcap`) read/write; DDS Security; action-server fan-out; a minimal `xacro` / URDF parser.

## Contributing

PRs welcome. The wire fixtures in [`Tests/SwiftROS2WireTests/`](Tests/SwiftROS2WireTests/) and golden CDR tests in [`Tests/SwiftROS2CDRTests/`](Tests/SwiftROS2CDRTests/) are the canonical guardrails — keep them green. [`Tests/SwiftROS2IntegrationTests/`](Tests/SwiftROS2IntegrationTests/) boots a real ROS 2 subscriber; set `LINUX_IP=<host>` to exercise it. Lint with `swift format lint --strict --configuration .swift-format Package.swift Sources Tests` before pushing — CI fails lint before any build matrix runs.

## License

Apache License 2.0. See [LICENSE](LICENSE).
