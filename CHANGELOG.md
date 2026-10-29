# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Internal

- Tests: `DiscoveryConfigFailLoudTests` uses domain 83 instead of 42. When every test target runs in one process (`swift test --build-system native`, Xcode), `DDSRoundTripTests` had created domain 42 first, so the session opened without the rejected config and the test failed.

### Fixed

- **Wire DDS reader teardown race.** A reader's active flag was a plain `bool`. The listener reads it on the thread that delivers a sample, which is the writing thread for a writer in the same process, while `dds_bridge_destroy_reader` cleared it on another thread. Thread Sanitizer reported this as a data race (#326). The reader's and the writer's flags are now atomic. No change in behavior: `dds_delete` already waited for the listener call in flight, so the reader was never used after it was freed.

## [3.1.0-rc.1] - 2026-10-24

Release candidate for 3.1.0, a minor release: the topic graph, latest-only and handler-at-creation subscriptions, per-distribution layouts and type hashes, and the results of canceled and aborted action goals. Until 3.1.0, depend on it with `exact: "3.1.0-rc.1"`; `from: "3.1.0"` resolves only once 3.1.0 is tagged. The binary targets keep their assets (`CZenohPico` the 3.0.2-rc.1 assets, the others the 2.3.0 assets): no source they are built from changed, and the new CDDSBridge and CRclBridge code is compiled from source.

### Added

- **Topic graph.** `ROS2Context.topicGraph()` returns every published topic of the context's domain as `TopicInfo` values (name, ROS type, and an `EndpointQoS` per publisher with its reliability, durability, node name and namespace), one per topic name and type, sorted. Hidden action topics and the caller's own publishers are included. On wire Zenoh each call queries the router for the `MP` liveliness tokens and waits at most 1.5 s; a query the router never finishes is abandoned after 10 s, and three abandoned queries mark the session graph-stalled, which turns `isConnected` false while publishing keeps working. Wire Zenoh, wire DDS and RCL all list topics. The token parser is pinned by tokens captured from rmw_zenoh_cpp on Humble, Jazzy and Lyrical hosts.
- **Topic graph on wire DDS.** `topicGraph()` reads the writers CycloneDDS has discovered (the builtin `DCPSPublication` topic) on a serial queue owned by the session, never on the Swift concurrency pool. Only `rt/` topics are listed, with the ROS topic name and type. Reliability maps RELIABLE to reliable and anything else to best effort; durability maps TRANSIENT_LOCAL or stronger to transient-local and anything else to volatile. Each writer is attributed to its node from the `ros_discovery_info` records the session now reads (16- and 24-byte gids, so Humble hosts too), and the writers of the wire DDS sessions in the process from the sessions themselves. A writer whose node is not known yet, or whose participant publishes no record, is listed with `_NODE_NAME_UNKNOWN_` and `_NODE_NAMESPACE_UNKNOWN_`. Discovery is asynchronous: right after a context opens, remote publishers can be missing, and a remote publisher that went away without saying so stays listed until its participant's lease expires.
- **Topic graph on RCL.** `topicGraph()` reads rcl's graph (`rcl_get_topic_names_and_types`, then `rcl_get_publishers_info_by_topic` per name) through a new CRclBridge call, `crcl_graph_snapshot`, on `rmw_cyclonedds_cpp` and `rmw_zenoh_cpp` alike. Names and types come from rmw in ROS form; RELIABLE reads as reliable, TRANSIENT_LOCAL as transient-local, and every other value (system default, unknown, best available) as best effort and volatile. The graph is read through an internal node, `_swift_ros2_graph` in `/`, which the first call creates and the context's shutdown destroys before the rcl context; no publisher, subscription or service is ever bound to it. Every snapshot runs under one lock on a serial queue owned by the session, never on the Swift concurrency pool, and inside the signal mask scope of the other CRclBridge calls that can start DDS threads. rmw fills its graph cache asynchronously, so an early result can miss publishers, and a publisher without `ros_discovery_info` (such as the raw writers used for types without bundled typesupport) carries rmw's unknown node strings. The C bridge is compiled from source; the `CRos2` / `CRos2Zenoh` assets are unchanged.
- **Latest-only delivery and handler-at-creation subscriptions.** `SubscriptionDelivery` and two `ROS2Node.createSubscription` overloads that take it. `.latestOnly` keeps only the newest message: the transport's receive thread stores the raw payload in a one-message slot and returns, and a serial delivery queue owned by the subscription decodes it and calls the handler, so a slow handler never blocks the transport and a replaced payload is never decoded. Its `messages` stream is finished at creation, and its reader uses history `keepLast(1)`. The `handler:` overload stores the handler before the transport subscriber exists, so a transient-local sample replayed during creation reaches it. `createSubscription(_:topic:qos:)` is unchanged (`.stream`).
- **Results of canceled and aborted action goals.** `ActionGoalHandle.wrappedResult(timeout:)` returns an `ActionWrappedResult`: the terminal `status` (succeeded, canceled or aborted) and the `result` the server sent with it, decoded with the context's distribution for every terminal status. rcl action servers send the full result with every terminal status, and some report the reason for a failure there (MoveIt's `move_group` aborts a goal it cannot plan or execute with `error_code` set), but `result(timeout:)` returns `.canceled` and `.aborted(reason: nil)` without it, and `ActionResult` cannot change in 3.x. `wrappedResult(timeout:)` waits and throws like `result(timeout:)`; a succeeded result that does not decode still throws `ActionError.responseDecodingFailed`, while a canceled or aborted reply whose result does not decode (such as the status-only reply of a swift-ros2 server before 3.0) gives `result == nil`, since the terminal status is known. `ActionWrappedResult.actionResult` converts to `ActionResult`, and `ActionWrappedResult` is `Equatable` when the result is. `result(timeout:)` is unchanged and now reads the reply through the same decode path.

### Changed

- **Per-distribution layouts and type hashes.** Messages, services and actions whose fields or hashes differ among Jazzy and later distributions now go out with the layout and the hash of the context's `distro`. Publishers, subscriptions, service servers and clients, and action servers and clients take their names and hashes from `typeInfo(for: context.distro)` and encode and decode with `CDREncoder(distro:)` / `CDRDecoder(data:distro:)`, so a generated type sees the real distribution in its `schemaDistro` guards. Before, such a type went out with the Jazzy layout and hash on every distribution after Humble, and a Lyrical peer never matched it (on Zenoh the hash is part of the key expression). Packages generated with swift-ros2-rosidl 1.1 that have such types need this release. Types that are the same on every distribution after Humble, Humble itself, and the DDS and RCL type names are unchanged. The swift-ros2-rosidl requirement is now `from: "1.1.0"`.

### Fixed

- **Wire DDS transient-local subscriptions in one process.** A transient-local subscription created after a publisher in the same process had published got the cached samples only once the next live sample arrived: CycloneDDS hands them over while the reader is being created, before its listener is armed. The client now takes them right after creating the reader, once it has released its own lock, so they are delivered at once and only once. This applies to every wire DDS reader (subscriptions, service and action readers): those samples normally reach the handler on the thread that creates the reader, before the create call returns; if a listener call is passing the reader's samples on at that moment, they reach it on that listener thread instead. All others still arrive on a CycloneDDS listener thread, and calls for one reader never overlap.

### Documentation

- The topic graph and the delivery modes are documented: README sections "Subscription delivery" (with how wire Zenoh, wire DDS and RCL deliver transient-local samples to late joiners) and "Topic graph" (what each transport can observe, and the wire Zenoh deadline and stalled-query rules), new Known limitations, a MIGRATION.md "3.0 → 3.1" section, the DocC articles "Receiving Messages" and "Discovering Topics" with their topic groups, the delivery and graph paths in ARCHITECTURE.md, and a `subscribe.latest_only` PARITY row. The new snippets are compiled by `DocumentationSnippetTests`. Three DocC link warnings in the Actions article are fixed.
- `ActionGoalHandle.wrappedResult(timeout:)` is documented in the Actions DocC article, the MIGRATION.md "3.0 → 3.1" section and the README; its snippet is compiled by `DocumentationSnippetTests`.

### Internal

- CI: a Thread Sanitizer job (macOS and Linux) runs the delivery tests, and a nightly `memory-soak` workflow (not a PR gate) reports the footprint of a 720p image stream into `.latestOnly` and `.stream` subscriptions on each wire transport through the new `delivery-soak` harness. A wire Zenoh integration test pins the transient-local late joiner through the `handler:` overload.
- Tests: a `distro_test_msgs` fixture generated from a Jazzy and a Lyrical copy of its IDL (`Tests/FixtureIDL/`, regenerated by `Scripts/regenerate-internal-types.sh`), whose `Plan` gains a field in Lyrical, pins the hashes every entity hands the transport on each distribution, the bytes it writes and reads, and the wire Zenoh key expressions and liveliness tokens.

## [3.0.2] - 2026-10-17

Patch release. The code is 3.0.2-rc.1 plus the `CZenohPico` asset pin below. It passed live checks against a ROS 2 Jazzy host running `rmw_zenohd` with a robot publishing reliable odometry, TF, battery, diagnostics and map topics and best-effort scan and compressed image topics: a client on the 3.0.2-rc.1 asset subscribed to all 7 topics for 180 s with no session losses and no gaps, every topic at its full rate, while publishing `sensor_msgs/Joy` to the host (received), where the same client on the 3.0.1 asset lost the session 12 times in 180 s; `ZenohBatchFramesTests` passes with the pinned asset and fails with the 3.0.1-rc.1 asset; and a mobile app built against this revision ran 5 minutes against that host with no session drops (about 45 before the fix).

### Fixed

- Apple builds get the wire Zenoh batch fix: `Package.swift` points the `CZenohPico` `binaryTarget` at the 3.0.2-rc.1 assets, built from the fixed zenoh-pico (swift-ros2/zenoh-pico#4), so a session no longer drops when one batch mixes reliable and best-effort frames. The other binary targets keep the 2.3.0 assets.

## [3.0.2-rc.1] - 2026-10-17

Release candidate for 3.0.2, a patch release with one wire Zenoh fix. The release workflow builds `CZenohPico` assets from the fixed zenoh-pico; until `Package.swift` points at them, Apple builds keep the 3.0.1-rc.1 assets and the session drops.

### Fixed

- Wire Zenoh sessions no longer drop when one batch from the router carries both reliable and best-effort samples. zenohd packs the messages for a session into one batch and starts a new frame in it whenever the reliability changes. zenoh-pico read everything after a frame header as that frame's network messages, so it failed on the next frame header ("unknown message type"), lost the rest of the batch and closed the session. A ROS 2 host with both reliable and best-effort publishers (odometry, TF, scans, compressed images) cut the session every few seconds: 6 to 44 times in 180 s against a ROS 2 Jazzy robot, and 0 times with the fix. zenoh-pico now ends a frame at the next transport message header and leaves that message to the batch loop (swift-ros2/zenoh-pico#4). The Linux, Windows and Android source builds get the fix from `vendor/zenoh-pico`; the Apple platforms get it once `Package.swift` points at `CZenohPico` assets built from this source.

### Internal

- `ZenohBatchFramesTests` pins the fix without a router: `FakeZenohRouter`, a TCP listener in the test target, completes the client handshake and sends one batch with a best-effort, a reliable and another best-effort frame, then a second batch, and the test checks that all five samples arrive in order and the session stays healthy. On Apple it runs only with `SWIFT_ROS2_ZENOH_LOCAL=1` until the `CZenohPico` assets carry the fix; CI's `Test (macOS, CZenohPico from source)` job now runs it too.

## [3.0.1] - 2026-10-16

Patch release. The code is 3.0.1-rc.1 plus the `CZenohPico` asset pin below. It passed live checks against a ROS 2 Jazzy host: wire Zenoh `sensor_msgs/Image` messages of 300 KB and 3 MB in both directions with no loss (3.0.0 received none), `ZenohLargeMessageTests` through the router with the pinned asset, and a wire DDS and an RCL DDS context with a unicast peer reaching two ROS 2 nodes on that host in both directions (3.0.0 reached one), plus the wire Zenoh and wire DDS topic and service regression cells.

### Fixed

- Apple builds get the wire Zenoh large-message fix: `Package.swift` points the `CZenohPico` `binaryTarget` at the 3.0.1-rc.1 assets, built from the fixed zenoh-pico (#305). The other binary targets keep the 2.3.0 assets.

## [3.0.1-rc.1] - 2026-10-16

Release candidate for 3.0.1, a patch release with two transport fixes. The release workflow builds `CZenohPico` assets from the fixed zenoh-pico; until `Package.swift` points at them, Apple builds keep the 2.3.0 assets and the 4 KB receive limit.

### Internal

- The vendored zenoh-pico and CycloneDDS forks moved from `youtalk/` to the `swift-ros2` org (`swift-ros2/zenoh-pico`, `swift-ros2/cyclonedds`), and `.gitmodules` points there. The old URLs redirect, so existing clones keep working.

### Fixed

- A wire DDS or RCL DDS context with unicast peers is now discovered by every ROS 2 node on a Linux peer host, not only by the most recently started one. Each peer is given to CycloneDDS as `host:port` and also as the bare host, so SPDP reaches each participant's own unicast port as well as the shared discovery port. On Linux, a unicast datagram to the shared port reaches only the newest of the sockets bound to it (youtalk/conduit#123).
- Wire Zenoh receives messages larger than 4 KB. zenoh-pico splits a message larger than the session's 2 KB batch into fragments and drops a received one whose fragments add up to more than its compile-time `Z_FRAG_MAX_SIZE`, which was zenoh-pico's default of 4096. Subscriptions and service clients never saw, for example, a `sensor_msgs/Image` or a `PointCloud2` from an `rmw_zenoh_cpp` publisher, and nothing reported the drop; publishing large messages was not affected. zenoh-pico is now built with a 64 MiB limit, both in the vendored `config.h` that the Linux, Windows and Android source builds compile with and in `Scripts/build-xcframework.sh` for the `CZenohPico` xcframework. The reassembly buffer is allocated when the first fragment of a message arrives and freed after the message is delivered, and only the pages the message fills become resident. The Apple platforms get the fix once `Package.swift` points at `CZenohPico` assets built from this source.
- Wire Zenoh no longer stops receiving large messages after the router drops one. zenoh-pico sent every fragment of a message with its reliability flag inverted (upstream eclipse-zenoh/zenoh-pico#1306, backported), so zenohd treated a large message from a reliable, Block publisher as best effort and dropped it whenever its queue toward a slow subscriber was full. And zenoh-pico did not negotiate QoS, so zenohd kept a single queue for the session, whose congestion flag (set under `Priority::Data`, cleared under `Priority::Control`) stayed set after one drop: the router then discarded every later best-effort or Drop message to that subscriber, including all fragmented ones, while the session looked healthy. zenoh-pico now negotiates QoS (one queue per priority on the router, receive state per priority), so a drop costs only the dropped message, and reliable Block messages are no longer dropped. Same platform note as above: Apple gets it with the next `CZenohPico` assets.

## [3.0.0] - 2026-10-16

First stable 3.x release. The code is the same as 3.0.0-rc.5, which passed the live interop matrix against ROS 2 Humble, Jazzy, Kilted and Lyrical hosts over wire Zenoh, wire DDS and RCL, a fresh-user walkthrough of the README and MIGRATION guide, and Conduit's migration onto it. It requires swift-ros2-rosidl 1.0.0; the standard message types are in swift-ros2-common-interfaces 1.0.0. `Package.swift` keeps the 2.3.0 `binaryTarget` assets.

The changes since 2.3.2 are in the release-candidate sections below:

- **Three packages** (rc.1). swift-ros2 moved to the `swift-ros2` org. The CDR codec, message protocols and generator moved to swift-ros2-rosidl, and the standard messages moved to swift-ros2-common-interfaces. See `MIGRATION.md`.
- **Wire interop with the rmw implementations** (rc.2, rc.3):
  - service and action keys use the service-level type hashes;
  - wire Zenoh announces the real node, with a GID per publisher and client;
  - wire DDS nodes appear in the ROS graph through `ros_discovery_info`;
  - late-joining action clients get the current status.
- **Public API trimmed before the freeze** (rc.2, rc.3). `ActionError.cancelRejected` carries a `CancelRejection` reason.
- **Signals** (rc.4, rc.5). On macOS, creating a wire DDS or RCL DDS context no longer leaves SIGINT and SIGTERM blocked.

### Known issues

- The README's Known limitations apply:
  - one publisher per topic per context on the wire DDS transports;
  - no ROS graph visibility for RCL nodes on Humble hosts;
  - the RCL zenoh variant has no typesupport for some message types.
- Wire DDS and RCL DDS can't share a domain id in one process ([#296](https://github.com/swift-ros2/swift-ros2/issues/296)).
- The RCL publish overhead from rc.1 is still open ([#224](https://github.com/swift-ros2/swift-ros2/issues/224)).

## [3.0.0-rc.5] - 2026-10-16

Release candidate for 3.0.0. It extends the rc.4 signal fix to the RCL transports. `Package.swift` keeps the 2.3.0 `binaryTarget` assets.

### Fixed

- Creating an RCL node on macOS no longer leaves SIGINT and SIGTERM blocked on the main thread, so Ctrl-C and `kill` stop the process again (#290). `rmw_cyclonedds_cpp` creates the CycloneDDS domain on the context's first node, and CycloneDDS starts its threads with `sigprocmask()`, which on Apple platforms sets the mask of every thread; `crcl_node_create` and `crcl_context_create` now run it with the main thread's mask and give the calling thread its own mask back, through the same helper (`CSignalMask`) as the wire DDS bridge.

## [3.0.0-rc.4] - 2026-10-16

Release candidate for 3.0.0 after the rc.3 user-side checks. `Package.swift` keeps the 2.3.0 `binaryTarget` assets. It requires the stable swift-ros2-rosidl 1.0.0 (#293).

### Fixed

- Creating a wire DDS context on macOS no longer leaves SIGINT and SIGTERM blocked on the main thread, so Ctrl-C and `kill` stop the process again. CycloneDDS starts its threads with `sigprocmask()`, which on Apple platforms sets the mask of every thread; `dds_bridge_create_session` now runs it with the main thread's mask and gives the calling thread its own mask back (#292, fixes #290).

### Documentation

- The README has a Known limitations section: one publisher per topic per context on the wire DDS transports, and no RCL graph visibility on Humble hosts. The README, the Examples guide, the Actions article and MIGRATION.md are corrected where they had gone stale (#291).

## [3.0.0-rc.3] - 2026-10-15

Last release candidate before the 3.0.0 API freeze. `Package.swift` keeps the 2.3.0 `binaryTarget` assets; rc.3 changes only source-built code. It requires swift-ros2-rosidl 1.0.0-rc.3 (#274).

### Changed on the wire

- **Wire Zenoh topics are announced under their real node** instead of a synthetic `ios_<topic>_node`, subscriptions announce themselves on every distro, and each node declares the `NN` token rmw_zenoh_cpp uses to drop it from the graph (#265).
- **Every wire Zenoh publisher and client has its own GID**, the 128-bit XXH3 hash of its liveliness token as in rmw_zenoh_cpp, instead of one GID per session (#267).
- **Hashless topics on Jazzy and later are keyed like services** (no `TypeHashNotSupported` segment) (#266).
- **Wire DDS nodes appear in the ROS graph:** each session publishes `ros_discovery_info` (`ParticipantEntitiesInfo`, with the per-distro Gid layout), so `ros2 node list/info`, `ros2 param` and `ros2 topic info -v` see Swift nodes (#272, fixes #200).

### Fixed

- The action status publisher keeps its transient-local cache, so a late-joining client gets the current status (#269).
- Action status snapshots are sent in the order they are read; a finished goal could appear stuck in ACCEPTED (#262).
- Closing a wire DDS session deletes its participant instead of leaking it (#250).
- A raw-CDR sample built from an iovec gets the sertype's hash; a process mixing RCL and a wire DDS session could hang in CycloneDDS's instance lookup (#272).
- On the RCL backend, a service or action of a type without bundled typesupport throws `TransportError.unsupportedFeature`, as topics already did (#277).

### Changed (breaking)

- `ActionGoalHandle.cancel()` throws `ActionError.cancelRejected(reason:)` when the server refuses, with a new `CancelRejection` (`.rejected`, `.unknownGoal`, `.goalTerminated`, `.unknown`); it used to ignore the return code (#276, #288).
- Removed public API that did nothing or was never produced: `declareParameter(..., ignoreOverride:)`, three never-thrown `ROS2ParameterError` cases, `ActionError.goalCanceled` / `.goalAborted`, `TransportError.goalRejected` / `.goalUnknown` (#275, #276); `ROS2Distro.WireGroup` and the separate `createNode(name:namespace:)` overload (now one method with a defaulted `options:`) (#279); the dead Zenoh codec API (`ActionEntityKind`, deprecated service/action token builders, the request-typed key builder, `mangleTopicPath`) (#270).
- `RclTransportSession`, `RclClient` and the action transport types are `package`; the `SwiftROS2RCL` library product is removed (the target stays) (#278).
- See MIGRATION.md "2.x -> 3.0" for the full list, including the common-interfaces defaults change and the swift-ros2-rosidl rc.3 removals (#280).

### Documentation

- An explicit `TransportConfig.wireMode` overrides `ROS2Context(distro:)` on the wire; `ROS2Context` logs a warning when the two disagree (#288).
- README, ARCHITECTURE and DocC updated for 3.x, with the test environment gates (#263, #261, #280).

### Internal

- Dead code removed from the C bridges, the RCL/DDS/wire/transport helpers and the context/node state (#247, #248, #252, #253); shared CancelGoal codec, publish seam, node entity bookkeeping, DDS request/reply and type-name helpers (#281-#286).
- Tests: stale, duplicate and trivial tests removed, shared polling helpers, ParityMatrix runs on Xcode 27, DDS test domains outside the Windows ephemeral range, fixtures generated only for referenced types (#245, #246, #249, #251, #254, #268, #271).
- CI: cached and retried toolchain downloads, router-gated tests run against zenohd, checks on PRs into any branch, the rmw_zenoh drift guard on a warm cache, bench harness only in the RCL graph (#255, #256, #257, #258, #259, #260, #264, #273).

## [3.0.0-rc.2] - 2026-10-15

`Package.swift` keeps the `binaryTarget` URLs and checksums of the 2.3.0 release assets: rc.2 changes only source-built code (`CZenohBridge`, `CDDSBridge` and Swift). It requires swift-ros2-rosidl 1.0.0-rc.2.

### Fixed

- **Wire Zenoh services, actions and parameter services interoperate with rmw_zenoh_cpp** on Humble, Jazzy, Kilted and Lyrical. Services are keyed by the service type name and the service-level type hash (`ROS2ServiceTypeInfo.serviceTypeHash`); action `send_goal` / `get_result` / `cancel_goal` by their own service types and hashes. Servers and clients declare `SS` / `SC` liveliness tokens under the real node, action servers and clients `SS`/`MP` and `SC`/`MS` tokens (the old `SA` / `CA` tokens are gone), replies echo the request's sequence number and GID, and `waitForService` / `waitForActionServer` find servers through a liveliness query instead of an empty request (#234). A type generated without a service hash keeps the old request-typed key, logged once.
- **Wire Zenoh action feedback and status** no longer fail with `putFailed(-100)` (the first feedback of most goals aborted them): they go through one blocking publisher each and carry the 33-byte attachment, without which rmw_zenoh_cpp dropped them (#236). Action replies use no consolidation, which avoids a zenoh-pico decoder crash.
- **Wire Zenoh action clients and wire DDS action clients keep feedback and status in arrival order**; a terminal status or the get_result reply could close a goal's feedback stream before earlier feedback was delivered (#242, #243).
- **Action result and status frames are aligned to the message origin.** Results with 8-byte-aligned fields (for example `tf2_msgs/LookupTransform`) were corrupted in both directions, and status arrays with two or more goals were misread (#237).
- **Canceled, aborted and unknown goals get a full default result** from a Swift action server; rmw clients could not deserialize the old status-only reply, and an unknown goal got no reply (#238). New `ActionServerHandler.defaultResult()` (default: a zero-valued result; return `Action.Result()` to apply IDL defaults).
- **CancelGoal follows rcl:** only accepted and executing goals are cancelable; cancel-all and by-stamp skip finished goals, and a sweep with nothing to cancel returns `ERROR_NONE` (#240).
- **Lyrical publishers of messages with `uint8[]` fields reach wire Zenoh subscribers**: subscriptions listen on `<key>/_buf_cpu` too and announce themselves as CPU-only. `ROS2Context` passes its distro to the Zenoh session as the default wire mode, so `distro: .lyrical` now selects Lyrical wire behavior (#228).
- **Late-joining TRANSIENT_LOCAL wire Zenoh subscriptions receive the publishers' cached samples** (for example `/tf_static`), on every distro (#230).
- **Reliable wire Zenoh topic publishers block on congestion** instead of failing with -100 whenever another send is in progress on the session; TCP sends are bounded (5 s), so a stalled link reports the session lost instead of hanging (#239).
- **Wire Zenoh liveliness tokens encode QoS as rmw_zenoh_cpp does** (best effort and keep-all were swapped with the defaults) (#231, #235).
- **The wire DDS service client waits for both directions** before the first call; the first call after `waitForService` was always lost (#227).
- **`ROS2Context(transport:distro:domainId:)` honors `domainId`**, which every backend ignored; `ctx.config` reports the domain the session opened on (#229).
- **A failed `ROS2Context` open releases its session**, and closing a never-opened Zenoh session is a no-op (#241).

### Added

- `ROS2Subscription.decodeFailureCount`, and rate-limited logging of CDR decode failures, which were dropped silently (#232).

### Documentation

- Migration and onboarding: a module map and a table of helpers that moved with their types, the `Quaternion()` default change, `platforms:`, the Zenoh domain, Linux consumer setup, iOS local-network keys, and the RCL backend's supported types and hosts (#233).

## [3.0.0-rc.1] - 2026-10-14

### Changed

- **swift-ros2 moved to the `swift-ros2` GitHub org** (`https://github.com/swift-ros2/swift-ros2.git`) and split into three packages. Do not keep the old `youtalk/swift-ros2` URL in the same dependency graph as the new one.
- **Standard message types left swift-ros2.** They live in [swift-ros2-common-interfaces](https://github.com/swift-ros2/swift-ros2-common-interfaces); add that package and import the modules you use (`import SensorMsgs`, or `import CommonInterfaces`). `Range` is now `RangeMsg`, and `builtin_interfaces/Duration` is generated as `DurationMsg`.
- **swift-ros2 depends on [swift-ros2-rosidl](https://github.com/swift-ros2/swift-ros2-rosidl)** for the CDR codec, the `ROS2Message` protocols, the runtime interface types and `ROS2Distro` (its wire members stay in `SwiftROS2Wire` as an extension). `import SwiftROS2` still re-exports them.
- **RCL publishes through the serialized path only.** The typed-publish fast path is removed; nothing changes in caller code, and the C registries are generated from type-name lists by an internal tool.
- **The examples publish `example_interfaces/msg/String`** instead of `std_msgs/msg/String`.
- **The `binaryTarget` URLs point at `swift-ros2/swift-ros2`** and keep the 2.3.0 assets and checksums.

### Removed

- `AudioData` (generate it with `swift-ros2-gen` if you need it) and the `SwiftROS2CDR`, `SwiftROS2Messages` and `SwiftROS2Gen` products, `swift-ros2-gen` and `SwiftROS2GenPlugin`, which live in swift-ros2-rosidl with the same module names.
- **The IDL submodules** (`vendor/common_interfaces-*`, `vendor/rcl_interfaces-*`, `vendor/example_interfaces-jazzy`, …). The IDL that the internal example and test targets read is pinned in `idl.lock` and fetched by `Scripts/fetch-idl.sh`; a resolve clones only `vendor/zenoh-pico` and `vendor/cyclonedds`.

### Known issues

- On the RCL backend, publishing a small message costs about 1.2 µs more per call than in 2.3.2 (about 3x for `Imu`; about 15% on 64–120 KB payloads), mostly in `CDREncoder`. This is negligible at sensor rates. It is tracked for 3.0.x in [#224](https://github.com/swift-ros2/swift-ros2/issues/224).

## [2.3.2] - 2026-10-12

`Package.swift` keeps the `binaryTarget` URLs and checksums of the 2.3.0 release assets, because 2.3.2 changes only Swift code.

### Fixed

- **`ROS2Context.shutdown()` and `ROS2Node.destroy()` no longer hold a thread of Swift's cooperative pool while a close blocks.** A transport close can block for as long as the link stalls: a wire Zenoh publisher close takes the lock that a put stuck on a frozen TCP link holds, and closing a publisher first waits for its matched-subscriptions sampling, whose state read takes the same lock, and for a handler call that is running. Both functions made these calls on the cooperative pool, which is only as wide as the CPU core count, so as many concurrent teardowns as there are CPU cores, during a stall, stalled every task on the global concurrent executor. The closes now run on a serial dispatch queue owned by the context, and the functions suspend until the closes have finished. The order is unchanged: each node's entities, then its unregistration, then the session. The teardowns of one context now run one at a time, so a second `shutdown()` returns only after the first one's closes, and a node's `destroy()` waits for a teardown of the same context that started earlier. A context whose close is stuck does not delay the teardown of another context. `ROS2ParameterClient.close()` runs its closes on the same queue. A swift-ros2 callback that blocks until another teardown of the same context finishes can now deadlock when a close of that context that runs ahead of it waits for the callback, as a publisher close does for an `onMatchedSubscriptionsChanged` handler call that is running.

## [2.3.1] - 2026-10-11

`Package.swift` keeps the `binaryTarget` URLs and checksums of the 2.3.0 release assets, because 2.3.1 changes only source-built code (`CZenohBridge` and Swift).

### Fixed

- **Wire Zenoh reports a session that lost its router.** zenoh-pico (auto-reconnect off) keeps a client session open after its router stops answering, and its publishers kept the matching state they saw last. A topic without subscribers therefore reported `hasMatchedSubscriptions == false` forever, so a caller that publishes only with subscribers never published again, never saw a put fail and never reconnected. Such a session now reports unknown matching (`hasMatchedSubscriptions` is `true` and `onMatchedSubscriptionsChanged` reports `true`), `ROS2Context.isConnected` is `false`, and `publish` throws the recoverable `TransportError.sessionUnhealthy`, TRANSIENT_LOCAL publishers included (they used to cache the sample and report success). Plain publishers on such a session used to throw `TransportError.publishFailed` and now throw `TransportError.sessionUnhealthy`; both are recoverable. zenoh-pico notices the loss when the router's lease expires, one to two leases after the router goes silent: 60 to 120 s with `rmw_zenohd`'s 60 s lease.
- **Closing a wire Zenoh session after it lost its router no longer crashes** (a crash present in 2.3.0). Once zenoh-pico has torn the lost transport down, every undeclaration, query, query reply and `z_close` segfaults on it, so `ROS2Context.shutdown()` (and with it a reconnect) crashed. Once the loss is detected, the bridge no longer makes those calls: teardown frees swift-ros2's own handles and leaves the zenoh-pico state allocated, a bounded leak per lost router (it includes TRANSIENT_LOCAL publisher caches, up to their history depth). Creating publishers, subscriptions, services or actions on it throws `TransportError.notConnected`. A transport that fails during a call, and zenoh-pico's heartbeat for TRANSIENT_LOCAL publishers, can still crash; see #214 for the remaining limitations.

## [2.3.0] - 2026-10-10

### Added

- **Matched subscriptions on publishers.** `ROS2Publisher.hasMatchedSubscriptions` reports whether at least one subscription matches, and `onMatchedSubscriptionsChanged(_:)` calls a handler with the current state and then with every change (sampled every 50 ms). Wire Zenoh now declares a zenoh-pico publisher per topic and reads its matching status; volatile publishers still deliver with `z_put` on the declared key expression, so the first message after a publisher is created is not dropped, and TRANSIENT_LOCAL publishers put through zenoh-pico's advanced publisher. Wire DDS reads the writer's publication-matched count; RCL reads `rcl_publisher_get_subscription_count` (or the raw writer's count). A transport that cannot tell reports `true`.
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
  - **Phase 8** — `verify-hash-oracle` CI job in `hash-oracle.yml` (now [`interface-oracles.yml`](https://github.com/swift-ros2/swift-ros2-rosidl/blob/1.0.0-rc.1/.github/workflows/interface-oracles.yml) in swift-ros2-rosidl) that diffs generated `RIHS01_*` hashes against the canonical `share/<pkg>/{msg,srv,action}/<Type>.json` files inside an `osrf/ros:<distro>-desktop` Docker image (jazzy required, kilted / rolling continue-on-error) and a matching `--verify-hashes <docker-image>` CLI flag for local pre-flight checks (#91).

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
