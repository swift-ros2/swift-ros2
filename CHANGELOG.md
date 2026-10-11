# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.3.0] - 2026-10-10

### Added

- **Matched subscriptions on publishers.** `ROS2Publisher.hasMatchedSubscriptions` reports whether at least one subscription matches, and `onMatchedSubscriptionsChanged(_:)` calls a handler with the current state and then with every change (sampled every 50 ms). Wire Zenoh now declares a zenoh-pico publisher per topic and reads its matching status; delivery still uses `z_put` on the declared key expression, so the first message after a publisher is created is not dropped. Wire DDS reads the writer's publication-matched count; RCL reads `rcl_publisher_get_subscription_count` (or the raw writer's count). A transport that cannot tell reports `true`.
- **TRANSIENT_LOCAL on wire Zenoh.** A TRANSIENT_LOCAL publisher is declared as a zenoh-pico advanced publisher with rmw_zenoh's options (cache of the history depth, publisher detection, 500 ms sporadic heartbeats when reliable), so rmw_zenoh subscribers that join later receive the cached samples. Builds without advanced publication fall back to a plain publisher. The new `latched-talker` example publishes latched `std_msgs/String` samples for late-joiner checks.

### Changed

- **The README documents that the RCL xcframeworks are arm64-only.** They have shipped arm64-only slices since they were introduced in 1.3.0 (opt-in); RCL is on by default since 1.4.0, which is when x86_64 builds started to break by default. The README now gives the workarounds: arm64-only builds that keep RCL (`ARCHS=arm64`, `EXCLUDED_ARCHS[sdk=macosx*]=x86_64`, `ONLY_ACTIVE_ARCH=YES`), and `SWIFT_ROS2_DISABLE_RCL=1` for builds that must include x86_64.
- **zenoh-pico 1.7.1.** The vendored zenoh-pico moves from 1.1.0 to 1.7.1 (fork branch `swift-ros2-main-1.7`), built with interest, matching, the unstable API and advanced publication. Sessions start zenoh-pico's periodic scheduler task. `SWIFT_ROS2_ZENOH_LOCAL=1` resolves `CZenohPico` from `build/zenoh-pico/` for local development. zenoh-pico's auto-reconnect stays disabled, as in 1.1.0; swift-ros2 reconnects by opening a new session.
- The vendored zenoh-pico also matches a subscriber declaration by key when a router tags it with an unrelated interest id, so a publisher's matched state no longer stays false (seen with rmw_zenoh's Lyrical router).

### Fixed

- **The `macos-arm64` slice of `CRos2` / `CRos2Zenoh` is built for macOS 13.0** (it was 13.1), matching `.macOS(.v13)`, so linking it no longer emits `object file ... was built for newer 'macOS' version (13.1) than being linked (13.0)` warnings. The build now asserts that no object in a slice targets a newer OS than the slice, and rebuilds a reused build tree whose deployment target changed.

## [2.2.0] - 2026-10-09

### Changed

- **Apple RCL runs ROS 2 Lyrical.** `CRos2` / `CRos2Zenoh` are built from `release-lyrical-20260807`: rcl 10.4.4, `rmw_cyclonedds_cpp` 4.1.4 with CycloneDDS 11.0.1, and `rmw_zenoh_cpp` 0.10.7 with zenoh-c 1.10.1. They interoperate with Jazzy and Lyrical hosts (README "Interop").
- **Binary targets renamed:** `CRos2Jazzy` → `CRos2`, `CRos2JazzyZenoh` → `CRos2Zenoh`, release assets included. Nothing imports these modules, so the public API is unchanged.
- **`.dds` in the default Apple graph runs on the CycloneDDS inside `CRos2`** (11.0.1, type and topic discovery on, the iOS Wi-Fi padding carried as a patch). Wire-only graphs (`SWIFT_ROS2_DISABLE_RCL=1`) and the zenoh variant keep `CCycloneDDS` 0.10.5.
- **One CycloneDDS per RCL-enabled cyclonedds graph on Apple.** Lyrical's CycloneDDS aborts at node creation when a binary carries two builds, so the `CRos2` one is the only copy linked.
- **The zenoh variant registers an empty `rosidl_buffer_backend` marker** in the ament prefix the RCL client synthesizes, so rmw_zenoh_cpp 0.10 finds no buffer-backend plugins and logs no ClassLoader ERROR at init. Inherited `AMENT_PREFIX_PATH` entries that declare buffer-backend plugins are dropped for the process (one stderr warning), so host plugins are never dlopen'd; other entries are kept.

## [2.1.0] - 2026-10-08

### Added

- **ROS 2 Lyrical Luth.** `ROS2Distro.lyrical` joins the modern wire group (same key expressions and type hashes as Jazzy). **Source-level note:** exhaustive `switch` statements over `ROS2Distro` need a `.lyrical` case or a `default` — new distributions ship in minors by policy (see `MIGRATION.md` "2.0 → 2.1").
- The hash oracle runs against `osrf/ros:lyrical-desktop` as a required job, and weekly on a schedule.

### Changed

- `swift-ros2-gen` derives every distro list from `IRBuilder.distroOrder` (new: `IRBuilder.modernDistros`). A `@lyrical` input is now merged instead of being silently dropped.

## [2.0.0] - 2026-09-22

2.0.0 removes the wire clients from the public API; the wire runtime remains the internal fallback where RCL is not available and is retired per platform in 2.x minors, non-breaking.

### Removed

- **Library products** `SwiftROS2Zenoh` and `SwiftROS2DDS`. Depend on `SwiftROS2` instead.
- **Public types** `ZenohClient`, `ZenohQueryable`, `DDSClient`, `ZenohTransportSession`, `DDSTransportSession` and `RMWRequestId` (now `package`). Use `ROS2Context` — see the "1.x → 2.0" section of `MIGRATION.md`.

### Changed

- **The wire runtime is now an internal fallback, reachable only through `ROS2Context`.** Routing is unchanged from 1.4.0 and decided by the build graph. `.zenoh(locator:)` runs on the wire path everywhere except the Apple zenoh-rmw variant (`SWIFT_ROS2_RCL_RMW=zenoh`) and Linux with `SWIFT_ROS2_ENABLE_RCL=1`, where it runs on `rcl` + `rmw_zenoh_cpp`. `.ddsMulticast` / `.ddsUnicast` run on the wire path wherever CycloneDDS is built (every Apple graph, Linux without RCL, Windows with `CYCLONEDDS_DIR`), on `rcl` + `rmw_cyclonedds_cpp` on Linux RCL builds, and throw on Android and DDS-less Windows. `.rcl` / `.rclUnicast` run on `rcl` + `rmw_cyclonedds_cpp` on the default Apple graph and Linux RCL builds, and throw `TransportError.unsupportedFeature` elsewhere. Full table in the README's "Backends" section.
- **Wire-transport action frames and DDS service request headers now use the upstream layout** (single CDR encapsulation header; 16-byte DDS request header instead of 24 bytes). **A 1.x peer on a wire transport does not interoperate with a 2.0 peer for actions (DDS and Zenoh) or DDS services** — including the DDS-wire parameter services, which are DDS services — upgrade both sides. 1.x peers on the RCL backend (e.g. `.rcl`) are unaffected; topics and Zenoh services are unchanged. See the "1.x → 2.0" section of `MIGRATION.md` (#115).

### Fixed

- DDS services and actions interoperate with `rmw_cyclonedds_cpp` (16-byte request header; single encapsulation header in action frames, DDS and Zenoh) — diagnosis by @daisukes. Because the parameter services are DDS services on the DDS wire path, `ros2 param` against a DDS-wire node now interoperates too (#115).
- **`ActionGoalHandle.result()` / `result(timeout: nil)` no longer trap.** A missing or unrepresentably large timeout (e.g. `.seconds(Int.max)`) was handed to `Task.sleep`, whose nanosecond conversion trapped with "Not enough bits to represent the passed value" on the DDS wire and RCL transports; such timeouts now wait for the reply instead. The DDS service `call` timeout race had the same trap and is fixed the same way (#190).

## [1.4.0] - 2026-09-21

The last 1.x minor and the bridge to 2.0.0. Tag `1.3.0` was cut before the
soft-deprecation and the RCL-default-on pin merged, so **1.4.0 is the first tagged
release that actually carries them.**

### Added

- **`SwiftROS2` umbrella on Android and DDS-less Windows** (Zenoh-only). `.dds` transports throw `TransportError.unsupportedFeature` where CycloneDDS is not part of the build (#179).
- **RCL backend on by default on Apple** with per-variant prebuilt xcframeworks (`CRos2Jazzy`, `CRos2JazzyZenoh`); opt out with `SWIFT_ROS2_DISABLE_RCL=1` (#174).

### Deprecated

- **Direct construction of the wire clients** — `ZenohClient()` / `DDSClient()`. They leave the public API in 2.0.0; the wire runtime remains the internal fallback behind `ROS2Context` (#173).

### Fixed

- **Unicast DDS discovery now reaches the configured port.** `DDSTransportSession` and `RclTransportSession` passed only `DDSPeer.address` into the CycloneDDS `<Peer address="..."/>` list, dropping `DDSPeer.port`. Without a port CycloneDDS patches in the *participant* unicast discovery port (`7400 + 250 * domain + 10`) and probes participant indices up to `MaxAutoParticipantIndex` — 7410, 7412, … 7426 on domain 0 — none of which a remote running the default `ParticipantIndex` ("none", ephemeral unicast ports) listens on. SPDP went to dead ports, discovery never completed, and nothing was reported: the failure looked exactly like a firewall or AP-isolation problem. Both call sites now emit the new `DDSPeer.discoveryAddress` (`host:port`, IPv6 bracketed), so SPDP lands on the port the caller configured. Thanks to @peichunhuang-1 for the diagnosis (#176, #177).
- **A discovery config CycloneDDS rejects now fails the session instead of degrading silently.** `dds_bridge_create_session` ignored a failed `dds_create_domain` and went on to `dds_create_participant`, which creates an *implicit* domain on the default configuration — multicast SPDP, no `<Peers>` — so the session reported itself connected while discovering nothing, the same "looks like a firewall" symptom as #176. The rejection is now surfaced as `DDSError.sessionCreationFailed`. "Domain already exists" (`DDS_RETCODE_PRECONDITION_NOT_MET`) stays tolerated: that is the documented process-lifetime limitation, where the config of the first session on a domain wins (#176, #177).
- rmw-serialized buffers no longer carry uninitialized CDR alignment padding (#162, #180).
- Zenoh sessions that only subscribe or serve are no longer dropped by `rmw_zenohd` 10 s after opening, and the process no longer dies of SIGPIPE afterwards: the vendored zenoh-pico now paces KEEP_ALIVE on the lowest of both leases (upstream eclipse-zenoh/zenoh-pico#953) while still expiring the router on the lease it advertised, actually sets `SO_NOSIGPIPE` on Apple, and no longer wakes at 1 kHz in `z_sleep_ms` (#116, #181). On Apple this takes effect with the xcframeworks pinned after this tag.

## [1.3.0] - 2026-07-13

### Added

- **Native RCL backend everywhere it can reach**: Apple Zenoh-RCL (`rcl` + `rmw_zenoh_cpp`) alongside the existing DDS variant, and Linux via a system ROS 2 install with the rmw chosen at runtime from the transport type. Opt-in via `SWIFT_ROS2_ENABLE_RCL=1` on every platform, including Apple — the Apple-default-on flip lands post-tag, first reaching a tag in 1.4.0 (#119–#164).
- **`TransportType.rcl`** plus the `TransportConfig.rcl(domainId:)` / `rclUnicast(peers:domainId:interface:)` factories (#120, #140). **Source-breaking for exhaustive `switch` statements over `TransportType`** — they need a `.rcl` case. `TransportType.allCases` includes `.rcl` on every build graph, including those where `ROS2Context` throws `TransportError.unsupportedFeature` for it.
- Parity matrix with latency / correctness / resource axes for both rmws (#159, #161, #166).

### Fixed

- Health pass from the multi-agent review: publisher topic-uniqueness, refcounted env slots, `TFMessage` sequence cap, empty-struct sentinel byte, four C-bridge memory bugs (#172).

## [1.2.0] - 2026-06-06

### Added

- **Source-timestamp publishing.** `ROS2Publisher.publish(_:timestamp:sequenceNumber:)` is a new additive overload that stamps the attachment's `timestamp_ns` field with a caller-supplied source timestamp (nanoseconds since the Unix epoch) — e.g. a sensor capture time — instead of the wall-clock publish time, and optionally takes an explicit attachment sequence number (defaulting to the publisher's own monotonic counter, just like `publish(_:)`). The existing `publish(_:)` now delegates to it with `Date()` and a nil sequence number, so its bytes are unchanged. Purely additive — no existing public API changed.

## [1.1.1] - 2026-05-16

### Fixed

- **`SwiftROS2GenPlugin` consumers now build for iOS via `xcodebuild`.** `xcodebuild` compiles a build-tool plugin's tool for the consuming target's destination platform, so any package that added `SwiftROS2GenPlugin` to a target could not be built for iOS / iOS Simulator. Two spots in the plugin's tool chain were not portable to embedded Apple platforms: `swift-ros2-gen` declared `@main` in `main.swift` — rejected by the compiler in top-level-code mode — fixed by renaming the single source file off `main.swift` so the module builds with `-parse-as-library`; and `SwiftROS2Gen`'s `OracleClient` spawned Docker via `Process` / `Pipe`, which are unavailable on iOS/tvOS/watchOS/visionOS, so the host-only `--verify-hashes` path is now guarded behind `#if os(macOS) || os(Linux) || os(Windows)`. No public API or wire-format change; the prebuilt xcframeworks are unaffected (#113).

## [1.1.0] - 2026-05-06

### Added

- **ROS 2 Parameter API.** Every `ROS2Node` now declares typed parameters with descriptors and ranges, exposes the six standard `rcl_interfaces` parameter services on `<node_fqn>/<service>` (`get_parameters`, `set_parameters`, `set_parameters_atomically`, `list_parameters`, `describe_parameters`, `get_parameter_types`), publishes `rcl_interfaces/msg/ParameterEvent` to `/parameter_events` on every successful declare / set / undeclare, and wires pre-set / on-set (with veto) / post-set callback registration. Wire-compatible with `ros2 param list/get/set/describe` against both `rmw_zenoh_cpp` (Zenoh) and `rmw_cyclonedds_cpp` (DDS). Six-phase rollout:
  - **Phase 1** — `rcl_interfaces` messages + services generated by `swift-ros2-gen` (#102).
  - **Phase 2** — node-side `ParameterStore` actor, `declareParameter` / `getParameter` / `setParameter` / `listParameters` / `describeParameter`, descriptor validation (range, read-only, dynamic typing) (#103).
  - **Phase 3** — auto-register the six parameter services on every node, with `ROS2NodeOptions(startParameterServices:)` opt-out (#104).
  - **Phase 4** — `/parameter_events` publisher (single-flight, lazy per node) plus pre/on/post-set callback registration; on-set callbacks veto by returning `successful: false` (#105).
  - **Phase 5** — `ROS2ParameterClient` for talking to a remote node's six parameter services from Swift; six thin async wrappers + `waitForService` (#106).
  - **Phase 6** — `ros2 param` CLI interop tests (LAN-gated), `Sources/Examples/ParameterDemo` runnable demo, README + MIGRATION sections (#107).
- **`QoSProfile.parameterEvents` preset** — reliable, transient-local, keep-last 1000; matches `rmw_qos_profile_parameter_events` so `/parameter_events` survives late-joining subscribers (#105).
- **`Sources/Examples/ParameterDemo`** — `swift run parameter-demo zenoh|dds` brings up a node with three declared parameters, an on-set callback enforcing a range invariant, and idle-loops so external tooling (`ros2 param`, `rqt_param`) can drive it (#107).

### Migration

No code changes required to upgrade. All additions are purely additive. See `MIGRATION.md` for a tour of the new public symbols. To opt out of the auto-registered parameter services, pass `ROS2NodeOptions(startParameterServices: false)` to `Context.createNode(name:namespace:options:)`.

## [1.0.0] - 2026-05-05

### Added

- **API stability promise.** swift-ros2 1.0.0 inaugurates the SemVer 1.x line — no breaking changes will land in 1.x without a 2.0 bump. See `MIGRATION.md` for the compatibility table.

### Changed

- **Public surface freeze.** Six visibility-only changes pull plumbing types out of the public API. End-user types (`ROS2Context`, `ROS2Node`, `ROS2Publisher`, `ROS2Subscription`, `ROS2Service`, `ROS2Client`, `ROS2ActionServer`, `ROS2ActionClient`, `QoSProfile`, `TransportConfig`, all message and service types) are unchanged. The concrete `ZenohClient` and `DDSClient` remain public.

### Removed

- (none — all removals are visibility demotions, covered under "Breaking changes" below.)

### Breaking changes

All six are visibility demotions out of the public API surface — downstream consumers can no longer name these types from outside the package. Inside the package, Candidates 1–4 use Swift 5.9's `package` access (cross-target visibility) and Candidates 5–6 use plain `internal` (single-target).

- **`TransportQoS` and `QoSPolicy` → `package`** (Candidate 1). Use `QoSProfile(reliability:, durability:, history:)` or one of the presets (`.sensorData`, `.reliableSensor`, `.latched`, `.servicesDefault`, `.actionDefault`).
- **`DDSBridgeQoSConfig`, `DDSBridgeDiscoveryConfig`, `DDSBridgeDiscoveryMode` → `package`** (Candidate 2). Configure DDS via `TransportConfig.ddsMulticast(...)` / `TransportConfig.ddsUnicast(...)`.
- **`ZenohClientProtocol`, `DDSClientProtocol`, and 10 related types → `package`** (Candidate 3): `ZenohKeyExprHandle`, `ZenohSubscriberHandle`, `ZenohLivelinessTokenHandle`, `ZenohQueryableHandle`, `ZenohQueryHandle`, `ZenohSample`, `ZenohError`, `DDSWriterHandle`, `DDSReaderHandle`, `DDSError`. Use the stock `ZenohClient()` / `DDSClient()` — both remain `public` — but the implementation-injection seam itself is gone: the cross-target plumbing that referenced these protocols (`TransportSession` / `TransportPublisher` / `TransportSubscriber` / the `ROS2Context.init(... session:)` 4-arg initializer / `*TransportSession` initializers) was demoted to `package` as a knock-on. Downstream code constructs a context with `ROS2Context(transport: TransportConfig)` and uses `node.createPublisher(...)` / `createSubscription(...)` / etc. to get the umbrella's public `ROS2Publisher` / `ROS2Subscription` / etc.
- **`EntityManager` and `GIDManager` → `package`** (Candidate 4). `ROS2Context` / `ROS2Node` manage them automatically; no external instantiation needed.
- **`ZenohTransportPublisher` concrete class → `internal`** (Candidate 5). The `TransportPublisher` protocol it conforms to was itself demoted to `package` as part of Candidate 3's knock-on; downstream code holds the umbrella's public `ROS2Publisher` from `node.createPublisher(...)`.
- **`DeclaredKeyExpr`, `ZenohSubscriber`, `LivelinessToken` → `internal`** (Candidate 6). They were always meant to be accessed via their handle protocols (which were themselves demoted to `package` in Candidate 3).

## [0.9.0] - 2026-05-04

### Added

- **`swift-ros2-gen` — IDL → Swift code generator (8-phase rollout).** A standalone CLI (`swift run swift-ros2-gen`) that reads ROS 2 `.msg` / `.srv` / `.action` IDL and emits `ROS2Message` / `ROS2ServiceType` / `ROS2Action` Swift sources with `CDRCodable` encoders and recorded `RIHS01_*` type hashes. Single-distro and multi-distro inputs both supported; multi-distro generation merges into one source file that branches on `encoder.isLegacySchema` / `decoder.isLegacySchema` for cross-distro field differences (e.g. `sensor_msgs/Range.variance`).
  - **Phase 1** — `swift-ros2-gen` skeleton + std_msgs migration (#84).
  - **Phase 2** — nested type references + geometry_msgs migration (#85).
  - **Phase 3** — fixed / variable arrays, constants, default values + UUID + action_msgs migration (#86).
  - **Phase 4** — distro-conditional generation + sensor_msgs migration (#87).
  - **Phase 5** — `.srv` support + std_srvs regeneration (#88).
  - **Phase 6** — `.action` support + per-action wrapper synthesis (`SendGoal_Request/Response`, `GetResult_Request/Response`, `FeedbackMessage`) + Fibonacci migration (#89).
  - **Phase 7** — SwiftPM build plugin (`SwiftROS2GenPlugin`) + `PluginSmoke` example target showing how to consume regenerated bindings from a downstream package (#90).
  - **Phase 8** — `verify-hash-oracle` CI job in [`hash-oracle.yml`](.github/workflows/hash-oracle.yml) that diffs generated `RIHS01_*` hashes against the canonical `share/<pkg>/{msg,srv,action}/<Type>.json` files inside an `osrf/ros:<distro>-desktop` Docker image (jazzy required, kilted / rolling continue-on-error) and a matching `--verify-hashes <docker-image>` CLI flag for local pre-flight checks (#91).

### Changed

- (intentionally empty — codegen is purely additive; no public API changed.)

## [0.8.0] - 2026-05-03

### Added
- **ROS 2 Actions — full server / client.** Six-phase rollout shipping `ROS2Action` type-system foundation, wire codecs, transport protocols, DDS transport, Zenoh transport, and the typed `ROS2ActionServer<H>` / `ROS2ActionClient<A>` umbrella API. Pure Swift Concurrency surface — `async throws` + `AsyncStream` for feedback / status, no callback shims. Built-in `example_interfaces/action/Fibonacci`. Examples: `swift run action-server zenoh` / `swift run action-client zenoh`. DocC chapter under `SwiftROS2/Documentation.docc/Articles/Actions.md`.
- **ROS 2 Actions — umbrella API + examples (phase 6 of 6).**
  - `ROS2ActionServer<H>`, `ROS2ActionClient<A>`, `ActionGoalHandle<A>`, `ActionServerHandler` protocol, public enums (`GoalResponse`, `CancelResponse`, `ActionGoalStatus`, `ActionResult`), `ActionError`.
  - `QoSProfile.actionDefault` — reliable / volatile / keep-last 10 (matches `rmw_qos_profile_services_default`).
  - `ROS2Node.createActionServer(_:name:qos:handler:)` and `createActionClient(_:name:qos:)`. `ROS2Node.destroy()` now also walks action servers / clients.
  - `ActionStatusEntry` public struct + `PublishesActionFeedback` public protocol on `SwiftROS2Transport` (the seam the umbrella server uses to publish feedback / status snapshots through the transport without a transport-specific downcast). `DDSTransportActionServerImpl` and `ZenohTransportActionServerImpl` conform.
  - `action-server` / `action-client` example binaries (Apple / Linux / DDS-on-Windows — gated alongside the umbrella).
  - LINUX_IP-gated `FibonacciActionTests` integration test.
  - DocC `Actions.md` chapter; `MIGRATION.md` 0.7 → 0.8 entry.
- **ROS 2 Actions — type-system foundation (phase 1 of 6, targeting 0.8.0).** Pure type-system work; no wire / transport / API changes yet.
  - `ROS2ActionTypeInfo` extended with synthesized-wrapper hashes (`sendGoalRequestTypeHash`, `sendGoalResponseTypeHash`, `getResultRequestTypeHash`, `getResultResponseTypeHash`, `feedbackMessageTypeHash`). Source- and ABI-compatible: the original 3-hash initializer is preserved as an explicit overload; the 8-hash initializer is a separate entry point.
  - `BuiltinInterfacesTime` (`builtin_interfaces/msg/Time`) — spec-correct `int32 sec`, `uint32 nanosec`. Distinct from `Header` (which keeps its legacy `UInt32 sec`).
  - Top-level wire messages (publishable through `ROS2Publisher`, write their own encapsulation header inside `encode`): `action_msgs/msg/GoalStatusArray` and `action_msgs/srv/CancelGoal` request/response. The wrappers `ActionSendGoalRequest<Goal>`, `ActionSendGoalResponse`, `ActionGetResultRequest`, `ActionGetResultResponse<Result>`, `ActionFeedbackMessage<Feedback>` are also top-level (per-action `typeName` / `typeHash` is supplied by the action's `ROS2ActionTypeInfo` at publish/subscribe time).
  - Nested CDR payloads (conform to `CDRCodable` only — same convention as `Header` and `Vector3` — so `ROS2Publisher` cannot accept them and emit invalid header-less CDR): `unique_identifier_msgs/msg/UUID` (with `Foundation.UUID` bridge; 16-byte invariant enforced via `private(set)` storage), `action_msgs/msg/GoalInfo`, `action_msgs/msg/GoalStatus`. `GoalStatusCode` (Int8) and `CancelGoalReturnCode` (Int8) enums ship for symbolic-name access.
  - Built-in action: `example_interfaces/action/Fibonacci` for examples and integration tests.
  - All sequence decodes use the existing `CDRDecoder` bound (`maxSequenceElements = 64 MiB`) — the manual `[GoalInfo]` / `[GoalStatus]` walks now go through a new public `CDRDecoder.readSequenceCount()` helper rather than `readUInt32()` directly, so a malicious wire frame cannot drive a giant `reserveCapacity` before decoding fails.
  - All `RIHS01_*` hashes are recorded from a live ROS 2 Jazzy install — they are not invented. Wire codec, transport, server/client, and umbrella API land in subsequent phases.
- **ROS 2 Actions — wire codec (phase 2 of 6, targeting 0.8.0).** Pure wire-format work; transports / API still upcoming.
  - `ZenohWireCodec.ActionRole` enum (`sendGoal` / `cancelGoal` / `getResult` / `feedback` / `status`) and `ZenohWireCodec.makeActionKeyExpr(role:domainId:namespace:actionName:actionTypeName:roleTypeHash:)` — emits the `<domain>/<ns>/<action>/_action/<role>/<dds_role_type>/<hash>` key expression with the same hash-segment rules as the Pub/Sub and Service paths (Humble: `TypeHashNotSupported`; Jazzy+: omitted when `nil`).
  - `ZenohWireCodec.ActionEntityKind` (`actionServer = "SA"`, `actionClient = "CA"`) and `makeActionLivelinessToken(...)` — single-anchor discovery on the `send_goal` request type, mirroring the existing `SS` / `SC` Service liveliness shape.
  - `DDSWireCodec.ActionTopicNames` + `actionTopicNames(namespace:actionName:actionTypeName:)` — returns all 8 `rq/`, `rr/`, `rt/` topics paired with their DDS type names. `cancel_goal` request/response and `status` use fixed `action_msgs` types (lifted to `TypeNameConverter.cancelGoalRequestDDSTypeName` / `cancelGoalResponseDDSTypeName` / `goalStatusArrayDDSTypeName` constants so the two codecs share the source of truth); the remaining five (`SendGoal_Request`, `SendGoal_Response`, `GetResult_Request`, `GetResult_Response`, `FeedbackMessage`) derive per-action via the new `TypeNameConverter.toDDSActionRoleTypeName(_:role:suffix:)`. `ActionTopicNames` exposes a public memberwise initializer (parity with `ServiceTopicNames`) so test mocks downstream of `SwiftROS2Wire` can construct one directly.
  - 25 golden tests under `Tests/SwiftROS2WireTests/ActionWireTests.swift` cover every codec path, namespace handling, leading-slash normalization, and Humble-vs-Jazzy hash differences. They pin the generated key-expression / topic / liveliness-token strings; strings are anchored to the Phase 1 recordings, none invented.
- **ROS 2 Actions — transport-layer protocols (phase 3 of 6, targeting 0.8.0).** Pure protocol-shape work; concrete DDS / Zenoh impls land in Phases 4 / 5.
  - `TransportActionServer` / `TransportActionClient` protocols on `SwiftROS2Transport` carry the lifecycle (`name`, `isActive`, `close`) plus per-client `waitForActionServer` / `sendGoal` / `getResult` / `cancelGoal`. Method bodies are still raw CDR — the umbrella API in Phase 6 will type-erase.
  - `SendGoalAck` / `GetResultAck` / `CancelGoalAck` raw-CDR ack structs and `ActionStatusUpdate` per-goal-id status filter.
  - `ActionRoleTypeHashes` — eight optional hashes the umbrella API extracts from `ROS2ActionTypeInfo` and the transport feeds into the wire codec.
  - `TransportActionServerHandlers` — three closures (`onSendGoal`, `onCancelGoal`, `onGetResult`) the umbrella API supplies to wrap the user's typed `ActionServerHandler`.
  - `ActionPendingTable` actor coordinates per-goal `feedback` / `status` / `result` continuations. Handles the result-before-register race by caching the terminal value, finishes streams on terminal status (4/5/6), and drains every pending goal on `failAll`.
  - `TransportSession.createActionServer(...)` / `createActionClient(...)` requirements with `unsupportedFeature`-throwing default implementations so Phases 4 / 5 can land in either order.
  - `TransportError`: new `goalRejected`, `goalUnknown`, `actionServerUnavailable` cases.
  - 14 new transport-tests cover the actor's full state machine and the default-impl throws.
- **ROS 2 Actions — DDS transport (phase 4 of 6, targeting 0.8.0).**
  - `DDSTransportSession.createActionServer(...)` and `createActionClient(...)` overrides — full server / client over rmw_cyclonedds-style rq/rr/rt topics. Reuses the existing service-pair and pub/sub primitives; no new C-bridge surface.
  - `DDSTransportActionServerImpl`: 3 service-pair handlers (`send_goal`, `cancel_goal`, `get_result`) + 2 publishers (`feedback`, `status`). Status topic uses `transient_local` depth 1 (matches rclcpp). `publishFeedback(goalId:feedbackCDR:)` and `publishStatus(entries:)` are the server-to-stream entry points.
  - `DDSTransportActionClientImpl`: 3 service-pair clients + 2 subscribers, with goal_id filtering on the shared `feedback` and `status` topics — each incoming frame is decoded, the goal_id extracted, and the matching `ActionPendingTable` entry yielded.
  - `ActionFrameDecoder` (internal): pure CDR helpers for the synthesized wrapper frames (encode/decode for `SendGoal{Request,Response}`, `GetResult{Request,Response}`, `FeedbackMessage`, `GoalStatusArray`). 8 round-trip + bounds tests.
  - `MockDDSClient` (test scope): new `serviceReplyHandler` closure + `deliverRequestSample` / `deliverSubscriberSample` test helpers, lets DDS action tests drive end-to-end flows in-process.
  - 9 new transport-tests cover server-side dispatch, client-side acceptance / rejection / result / cancel, goal-id filtering, and close-walk lifecycle.
- **ROS 2 Actions — Zenoh transport (phase 5 of 6, targeting 0.8.0).**
  - `ZenohTransportSession.createActionServer(...)` and `createActionClient(...)` overrides — full server / client over Zenoh queryables (3 services), publishers (`feedback`, `status`), and `SA` / `CA` liveliness tokens. Reuses `ActionFrameDecoder` from Phase 4; no new C-bridge surface.
  - `ZenohTransportActionServerImpl`: 3 queryables for `send_goal` / `cancel_goal` / `get_result`, plus 2 publishers and a single `SA` liveliness anchor on the `send_goal` request type.
  - `ZenohTransportActionClientImpl`: 3 `get(...)` callers, 2 subscribers with goal-id filtering routed through `ActionPendingTable`, a `CA` liveliness token announcement, and `waitForActionServer` that polls the `send_goal` queryable with a 200ms `get` until any reply lands or `timeout` elapses (throws `TransportError.actionServerUnavailable` on miss).
  - `MockZenohClient` (test scope): new `getReplyHandler`, `putsByKey`, `declaredLivelinessTokens`, `deliverQuery`, and `deliverSubscriberSample` test helpers.
  - 8 new transport-tests cover server queryable dispatch, feedback / status publication + liveliness, client send_goal / get_result / status filtering, and `waitForActionServer` timeout.
- **DDS on Windows** — full DDS path (CCycloneDDS, CDDSBridge, SwiftROS2DDS, the SwiftROS2 umbrella, the talker / listener / srv-server / srv-client examples, and the DDS / umbrella tests) now ships on Windows x86_64 when `CYCLONEDDS_DIR` points at a `vcpkg install cyclonedds:x64-windows` tree. Package.swift threads `-I<dir>/include` and `-L<dir>/lib` into CDDSBridge so `#include <dds/dds.h>` and the `-lddsc` link from the CCycloneDDS modulemap resolve against the vcpkg layout. `build-windows` CI now installs the vcpkg port, exports `CYCLONEDDS_DIR`, and runs the full `swift build` + `swift test --parallel`. (#37)

### Changed
- `Package.swift` Windows arm: `if !isWindowsBuild && !isAndroidBuild` gate replaced with a `canBuildDDS` flag that honors `CYCLONEDDS_DIR`. Without `CYCLONEDDS_DIR` the Windows arm keeps the 0.5.0–0.7.0 Zenoh-only shape; with it set, the umbrella + DDS targets join the build graph alongside the existing Zenoh path.

## [0.7.0] - 2026-05-01

### Added
- **Services** — typed `ROS2Service<S>` / `ROS2Client<S>` on top of new `TransportService` / `TransportClient` protocols, with end-to-end Server / Client support over both Zenoh (queryable + `get`) and DDS (rq/rr topics + sample-identity prefix). `ROS2Node.createService(_:name:qos:handler:)` / `createClient(_:name:qos:)` are the public entry points; built-in `std_srvs/srv/Trigger` ships with the package.
- `ServiceError` — public enum covering `.timeout`, `.serviceUnavailable`, `.handlerFailed`, `.requestEncodingFailed`, `.responseDecodingFailed`, `.clientClosed`, `.serverClosed`, `.taskCancelled`, and `.transportError`. Maps lower-level `TransportError` variants automatically.
- `srv-server` / `srv-client` example executables (`swift run srv-server zenoh`, `swift run srv-client dds`, etc.) over `std_srvs/srv/Trigger`.
- Service round-trip integration tests for both Zenoh and DDS (LINUX_IP-gated, plus a same-process DDS loopback that runs unconditionally).
- `ZenohClientProtocol.declareQueryable` / `get` (with `ZenohQueryableHandle` / `ZenohQueryHandle`) and matching DDS rq/rr primitives on `DDSClientProtocol`. `ZenohError.queryReplyError(String)` carries remote-handler errors through to `ServiceError.handlerFailed`.
- `TransportError.requestTimeout(Duration)` / `.requestCancelled` / `.serviceHandlerFailed(String)` and `RMWRequestId` / `SampleIdentityPrefix` for service request / reply correlation on DDS.
- DocC catalog under the `SwiftROS2` umbrella with getting-started articles (Zenoh, DDS) and a wire-format reference.
- `CHANGELOG.md` and `MIGRATION.md` (the latter with the 0.7 → 1.0 candidate change list).
- `Scripts/check-docc-coverage.sh` enforcing `///` comments on every public declaration.
- `docs-build` CI job running `swift package generate-documentation` on every PR.
- Per-target line-coverage gate in CI (`Scripts/coverage-gate.sh`, thresholds in `Scripts/coverage-thresholds.txt`).
- Internal helpers `AttachmentBuilder` and `TransportQoSMapper` (extracted from transport sessions).
- Unit tests for `Node`, `Publisher`, `Subscription`, and `QoSProfile` via mock session.
- Unit tests for `EntityManager`, `GIDManager`, `TransportConfig`, and transport session via mock Zenoh / DDS clients.
- `swift package diagnose-api-breaking-changes 0.6.1` enforced on every PR.

### Changed
- `ZenohTransportSession` and `DDSTransportSession` split into focused files. Both now walk `serviceServers` / `serviceClients` alongside publishers in `close()`.
- `ROS2Node.destroy()` now walks publishers, subscriptions, services, and clients in one teardown pass.

## [0.6.1] - 2026-04-28

### Added
- Services type-system foundation (phase 1): `ROS2ServiceType`, `ROS2ServiceTypeInfo`, `ROS2Service` in `SwiftROS2Messages`.

### Fixed
- CycloneDDS 11 `radmin` header rename support (#55).

## [0.6.0] - 2026-04-25

### Added
- Android cross-compile support (arm64-v8a, x86_64) over Bionic via the unix backend.
- Manifest-scope four-arm split (apple / linux / windows / android) keyed on `SWIFT_ROS2_TARGET_OS`.
- Comprehensive README overhaul with platform/coverage tables and CI badges.
- zenoh-pico bumped to version with `ZENOH_ANDROID` support.

### Fixed
- Android cross-compile from Linux host.

## [0.5.0] - 2026-04-25

### Added
- Android CI matrix (`build-android` per ABI, `test-android-x86_64` emulator job).
- Package.swift four-arm platform split with DDS carved out for Windows and Android.
- Windows cross-compile documentation in README.

## [0.4.0] - 2026-04-21

### Added
- DDS Subscriber (raw CDR reader path).
- Minimal `talker` / `listener` demo executables with CLI transport switch.
- Windows zenoh-pico source build (`build-windows`); DDS family carved out for Windows.

### Fixed
- `ZENOH_MACOS` define missing for iOS and visionOS builds.

## [0.3.1] - 2026-04-19

### Fixed
- Bound untrusted CDR sequence/string lengths to prevent buffer overread (#17).

## [0.3.0] - 2026-04-19

### Changed
- Drop the `Default` prefix from `ZenohClient` / `DDSClient`.
- Make `ZenohClientProtocol` / `DDSClientProtocol` public for client injection.

### Added
- Linux arm64 runners and ROS 2 Rolling added to the build matrix.
- Ubuntu 22.04 + ROS 2 Humble added to the Linux build matrix.

## [0.2.0] - 2026-04-19

### Added
- Initial public release: Zenoh + DDS publishers and subscribers, CDR XCDR v1 codec, 23 built-in message types.
