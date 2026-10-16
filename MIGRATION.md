# Migration Guide

## 2.x → 3.0

swift-ros2 moved to the `swift-ros2` GitHub org and split into three packages.

1. **URL.** Use `https://github.com/swift-ros2/swift-ros2.git`. Do not keep the old
   `youtalk/swift-ros2` URL anywhere in the same dependency graph: SwiftPM sees two locations
   for one package.
2. **Message types.** Standard messages left swift-ros2. Add
   [swift-ros2-common-interfaces](https://github.com/swift-ros2/swift-ros2-common-interfaces)
   and import the modules you use:

   ```swift
   .package(url: "https://github.com/swift-ros2/swift-ros2.git", from: "3.0.0"),
   .package(url: "https://github.com/swift-ros2/swift-ros2-common-interfaces.git", from: "1.0.0"),
   // target:
   .product(name: "SwiftROS2", package: "swift-ros2"),
   .product(name: "SensorMsgs", package: "swift-ros2-common-interfaces"),
   ```
   ```swift
   import SwiftROS2
   import SensorMsgs   // or `import CommonInterfaces` for every standard package
   ```

   In 2.x `import SwiftROS2` reached every message type, so a file that used `Imu`, `Header`
   and `Vector3` needed one import. Each ROS package is now its own module and a module does
   not re-export the ones it depends on, so that file needs one import per package whose type
   it names (`SensorMsgs`, `StdMsgs`, `GeometryMsgs`). The mechanical migration is to replace
   the messages you used from `SwiftROS2` with `import CommonInterfaces`, which re-exports
   every standard module; narrow it to single modules later if you prefer. See
   "Which module holds which type" below.
3. **Renames.** `Range` → `RangeMsg`; `builtin_interfaces/Duration` is generated as `DurationMsg`.
4. **Removed from swift-ros2.** `AudioData` (generate it with `swift-ros2-gen` if you need it),
   the `SwiftROS2CDR` / `SwiftROS2Messages` / `SwiftROS2Gen` products, `swift-ros2-gen` and
   `SwiftROS2GenPlugin` — they live in
   [swift-ros2-rosidl](https://github.com/swift-ros2/swift-ros2-rosidl) with the same module
   names; `import SwiftROS2` still re-exports CDR, the protocols, `ROS2Distro` and the runtime
   interfaces.
5. **RCL.** The typed-publish fast path is gone; every type publishes through the serialized
   path. Nothing changes in your code.
6. **Examples** publish `example_interfaces/msg/String` instead of `std_msgs/msg/String`.
7. **No IDL submodules.** swift-ros2 no longer carries ROS IDL (`vendor/common_interfaces-*`,
   `vendor/rcl_interfaces-*`, `vendor/example_interfaces-jazzy`, …); a resolve clones only the
   C-source submodules `vendor/zenoh-pico` and `vendor/cyclonedds`. If you ran
   `swift-ros2-gen` on IDL under `.build/checkouts/swift-ros2/vendor/`, pin your own: an
   `idl.lock` and a copy of swift-ros2-rosidl's `Scripts/fetch-idl.sh`, as
   swift-ros2-common-interfaces does.
8. **Zenoh codec helpers.** Three `SwiftROS2Wire` declarations that nothing on the wire uses
   are removed: `ZenohWireCodec.ActionEntityKind` (`SA` / `CA` tokens, which rmw_zenoh_cpp does
   not recognize; deprecated since 3.0.0-rc.2), `ZenohWireCodec.makeServiceKeyExpr(domainId:namespace:serviceName:serviceTypeName:requestTypeHash:)`
   (a request-typed key rmw_zenoh_cpp never answers; use the `serviceTypeHash:` overload with
   `ROS2ServiceTypeInfo.serviceTypeHash`) and `TypeNameConverter.mangleTopicPath(namespace:topic:)`.

### Removed public API

Declarations that did nothing, or that nothing could throw or reach, are removed before the 3.0
API freeze. Code that never named them compiles unchanged.

- `ROS2Node.declareParameter(_:default:descriptor:ignoreOverride:)` loses `ignoreOverride:`.
  swift-ros2 has no parameter-override source, so the flag had no effect; drop the argument.
- `ROS2ParameterError.immutableTypeChange`, `.outOfRange` and `.readOnly` are removed: no API
  threw them. A declare-time type or range violation throws `.invalidValue`; read-only, range
  and type failures of a set come back as `ROS2SetParametersResult.reason`. Delete `catch`
  clauses and `switch` cases that named them.
- `ActionError.goalCanceled` and `.goalAborted(reason:)` are removed: a canceled or aborted goal
  is reported by `ActionGoalHandle.result()` as `ActionResult.canceled` / `.aborted(reason:)`,
  never thrown. `TransportError.goalRejected` and `.goalUnknown` are removed too: a rejected goal
  throws `ActionError.goalRejected`.
- `ActionError.cancelRejected` gains a `reason: CancelRejection` payload (2.x declared the bare
  case but nothing threw it). Rewrite `catch ActionError.cancelRejected` as
  `catch ActionError.cancelRejected(reason: _)`, or match one reason; see "Behavior changes".
- The transport plumbing that no public API produces or accepts is `package` now:
  `RclTransportSession` (and its `checkHealth()`, which is removed), `RclClient` and the action
  transport types (`TransportActionServer`, `TransportActionClient`,
  `TransportActionServerHandlers`, `SendGoalAck`, `GetResultAck`, `CancelGoalAck`,
  `ActionStatusUpdate`, `ActionStatusEntry`, `ActionRoleTypeHashes`, `PublishesActionFeedback`,
  `ActionPendingTable`). They could only be used through the `package` `TransportSession`. The
  `SwiftROS2RCL` library product is removed, since it no longer has public API: depend on
  `SwiftROS2`, whose `.rcl` transport (and `.zenoh` / `.dds` where the build routes them to
  RCL) selects the backend.
- `ROS2Distro.WireGroup` and `ROS2Distro.wireGroup` are removed. Test `isLegacySchema` (Humble)
  or `supportsTypeHash` instead.
- `ROS2Context.createNode(name:namespace:)` and `createNode(name:namespace:options:)` are one
  method, `createNode(name:namespace:options:)` with `options` defaulting to `.default`. Every
  call compiles as before; only a reference to the two-argument function itself (for example
  `ctx.createNode(name:namespace:)` as a value) needs the third label.
- Through `import SwiftROS2`, which re-exports swift-ros2-rosidl, these are gone too: the
  3-hash `ROS2ActionTypeInfo(actionName:goalTypeHash:resultTypeHash:feedbackTypeHash:)` (use the
  full initializer, which `swift-ros2-gen` emits; the 3-hash form left every wrapper hash `nil`,
  which rmw_zenoh_cpp cannot match), the `ROS2Publishable` / `ROS2Subscribable` typealiases (use
  `ROS2Message`, or spell out `ROS2MessageType & CDREncodable`) and
  `CDRDecodingError.invalidArraySize`, which nothing threw. `CDRSerializationError`'s
  `invalidCovarianceArraySize`, `serializationFailed` and `bufferOverflow`, which nothing threw
  either, give way to the cases generated code now throws (`invalidArrayLength`,
  `sequenceTooLong`, `stringTooLong`; see "Behavior changes").

### Which module holds which type

| Module (package) | Holds | Reached by |
|---|---|---|
| `StdMsgs` | `Header`, `StringMsg`, `BoolMsg`, `Float64Msg`, `Int32Msg`, `ColorRGBA`, the `*MultiArray` types, `EmptyMsg`, … | `import StdMsgs` |
| `BuiltinInterfaces` | `Time` (the type of `Header.stamp`; also `Time.now()`), `DurationMsg` | `import SwiftROS2` or `import CommonInterfaces` (both re-export it), or `import BuiltinInterfaces` |
| `GeometryMsgs` | `Vector3`, `Point`, `Quaternion`, `Pose`, `PoseStamped`, `Transform`, `TransformStamped`, `Twist`, `Wrench`, … | `import GeometryMsgs` |
| `SensorMsgs` | `Imu`, `Image`, `CompressedImage`, `CameraInfo`, `PointCloud2`, `PointField`, `NavSatFix`, `NavSatStatus`, `BatteryState`, `RangeMsg`, `Joy`, `MagneticField`, `Temperature`, … | `import SensorMsgs` |
| `Tf2Msgs` | `TFMessage` | `import Tf2Msgs` |
| `StdSrvs` | `TriggerSrv`, `SetBoolSrv`, `EmptySrv` | `import StdSrvs` |
| `NavMsgs`, `DiagnosticMsgs`, `ShapeMsgs`, `StereoMsgs`, `TrajectoryMsgs`, `VisualizationMsgs` | `Odometry` and `Path`, `DiagnosticArray`, `SolidPrimitive`, … | `import <Module>` |
| `UniqueIdentifierMsgs`, `ActionMsgs`, `RclInterfaces` | `UniqueIdentifierUUID` (with `init(foundationUUID:)`), the action messages, the parameter messages | `import SwiftROS2` (re-exports them) |
| `SwiftROS2CDR`, `SwiftROS2Messages` | `CDRCodable`, `CDREncoder` / `CDRDecoder`, `ROS2Message`, `ROS2Distro` | `import SwiftROS2` (re-exports them) |

`import CommonInterfaces` re-exports every standard module in the table (and `BuiltinInterfaces`),
so one line replaces the per-package imports. A module also needs its own import for the helpers
in the next table: `Header` and `Header.now(frameId:)` are in `StdMsgs`, so with `import SensorMsgs`
alone the compiler reports `cannot find 'Header' in scope`.

### Helpers that moved with their types

The 2.3.2 hand-written helpers moved to the package that owns the type. Names and signatures
are unchanged, except that `Range` is `RangeMsg`. Each import below is the module to add (or
`CommonInterfaces` for all of them).

| 2.3.2 helper (reached via `import SwiftROS2`) | 3.0 module |
|---|---|
| `CovarianceConstants` (`unknown`, `unknownCovariance3x3()`, `zeroCovariance3x3()`) | `SensorMsgs` |
| `Header.now(frameId:)`, `Header.timestampNanoseconds`, `Header(sec:nanosec:frameId:)`, `Header.sec` / `.nanosec` | `StdMsgs` |
| `Quaternion.identity` | `GeometryMsgs` |
| `PointField.x(offset:)`, `.y(offset:)`, `.z(offset:)`, `.rgb(offset:)`, `PointField.xyzFields`, `PointField.xyzrgbFields`, `PointField(name:offset:datatype:count:)` taking `PointFieldDataType` | `SensorMsgs` |
| `PointFieldDataType` (`int8` … `float64`, `byteSize`) | `SensorMsgs` |
| `RegionOfInterest.fullFrame(width:height:)` | `SensorMsgs` |
| `NavSatStatus.statusNoFix` / `statusFix` / `statusSbasFix` / `statusGbasFix`, `serviceGPS` / `serviceGLONASS` / `serviceCOMPASS` / `serviceGALILEO` | `SensorMsgs` |
| `BatteryState.PowerSupplyStatus` / `PowerSupplyHealth` / `PowerSupplyTechnology` and the initializer that takes them | `SensorMsgs` |
| `RangeMsg.RadiationType` and `RangeMsg(…radiationType:)` (was `Range`) | `SensorMsgs` |
| `NavSatFix.CovarianceType` and `NavSatFix(…positionCovarianceType:)` | `SensorMsgs` |
| `CompressedImage` / `Image` / `PointCloud2` initializers that take `Data`, and `dataAsData` | `SensorMsgs` |
| `Time.now()`, `BuiltinInterfacesTime` | `BuiltinInterfaces` (re-exported by `SwiftROS2`) |
| `UniqueIdentifierUUID.init(foundationUUID:)`, `.foundationUUID` | `UniqueIdentifierMsgs` (re-exported by `SwiftROS2`) |

`CovarianceConstants` is the one that silently stops resolving: in 2.x `import SwiftROS2` was
enough, and in 3.0 `SwiftROS2` does not re-export `SensorMsgs`, so the compiler reports
`cannot find 'CovarianceConstants' in scope` until you `import SensorMsgs`.

### Behavior changes

- **`ActionGoalHandle.cancel()` throws when the server refuses.** It used to return normally for any
  `action_msgs/CancelGoal` return code. It now throws `ActionError.cancelRejected(reason:)` for
  every non-zero code, so a goal that is not canceling no longer looks canceled. The new
  `CancelRejection` enum carries which code it was: `.rejected` (`ERROR_REJECTED`),
  `.unknownGoal` (`ERROR_UNKNOWN_GOAL_ID`), `.goalTerminated` (`ERROR_GOAL_TERMINATED`, the goal
  had already finished) or `.unknown(Int8)` for a code the message does not define. To treat a
  goal that already finished as success, catch it by reason:

  ```swift
  do {
      try await handle.cancel()
  } catch ActionError.cancelRejected(reason: .goalTerminated) {
      // Already finished: nothing to cancel.
  }
  ```

  `ROS2ActionClient.cancelGoals(beforeStamp:)` is unchanged: it returns the goals that are canceling.
- **Generated types honour IDL default values.** `swift-ros2-gen` now emits the default of a
  field from the `.msg` file as the default of the initializer parameter. The one default that
  differs from all-zero in the standard messages is `geometry_msgs/Quaternion.w = 1.0`, so
  `Quaternion()` is the identity rotation (`w = 1`) where it was all zeros in 2.x. Every message
  that leaves a nested `Quaternion` at its default follows: a default `Pose`, `PoseStamped`,
  `Transform` and `TransformStamped` carry an identity orientation, and a default `Imu`
  (`Imu(header:linearAcceleration:)` and the like) publishes `orientation.w = 1` instead of an
  invalid all-zero quaternion; in 2.x only the zero-argument `Imu()` did, and it is unchanged.
  The bytes on the wire change for code that relied on the zero default. To keep the 2.x bytes,
  set the field explicitly: `Imu(orientation: Quaternion(x: 0, y: 0, z: 0, w: 0), …)`. Keep in
  mind that `w = 0` is not a valid rotation, so only do this if a consumer depends on it.
- **Zero-argument initializers give the IDL defaults.** In 2.x, `CameraInfo()`, `NavSatStatus()`
  and `BatteryState()` were hand-written initializers with their own values, which a call with
  any label did not get. In 3.0 they are the generated initializers, so they carry the IDL
  defaults that rclcpp and rclpy give a default-constructed message:

  | Call | 2.x | 3.0 |
  |---|---|---|
  | `CameraInfo()` | `distortionModel` `"plumb_bob"`, `r` the 3×3 identity | `distortionModel` `""`, `r` all zeros |
  | `NavSatStatus()` | `STATUS_FIX` (0) / `SERVICE_GPS` (1) | `STATUS_UNKNOWN` (-2) / `SERVICE_UNKNOWN` (0) |
  | `BatteryState()` | NaN measurements, `present = true` | zero measurements, `present = false` |

  `NavSatFix`'s typed initializer defaults `status` to `NavSatStatus()` and follows. To keep a
  2.x value, pass it: `NavSatStatus(status: NavSatStatus.STATUS_FIX, service: NavSatStatus.SERVICE_GPS)`,
  `CameraInfo(distortionModel: "plumb_bob", r: [1, 0, 0, 0, 1, 0, 0, 0, 1])`. The `BatteryState`
  initializer that takes `PowerSupplyStatus` / `PowerSupplyHealth` / `PowerSupplyTechnology`
  keeps NaN measurements and `present = true` whenever a call passes one of those enums.
- **Name clashes with the helpers.** A helper that now lives in a message module can collide
  with a declaration of the same name in your own code. A declaration in the same module as the
  use wins over the imported one, but one in another module of yours (a shared library target,
  or a module that a test target imports next to `SensorMsgs`) does not: a type such as
  `CovarianceConstants` is reported as `ambiguous use of 'CovarianceConstants'`, and an extension
  member such as `PointField.xyzFields` makes the compiler reject the expression. Conduit hit
  this with its own `PointField.xyzFields`. Remove your copy and use the one from `SensorMsgs`,
  or rename yours. This applies to any name in the tables above (`CovarianceConstants`,
  `PointFieldDataType`, `Quaternion.identity`, `Header.now(frameId:)`, …).
- **Generated code checks lengths instead of trapping.** Code from the swift-ros2-rosidl 1.0.0
  `swift-ros2-gen` throws `CDRSerializationError.invalidArrayLength` from `encode(to:)` for a
  fixed-size array of the wrong length (an `Imu` covariance that is not 9 elements, a `uuid` that
  is not 16 bytes) and `.sequenceTooLong` for a bounded sequence over its bound, where 2.x code
  stopped the process. Bounded strings (`string<=N`) are checked too: encoding an over-long value
  throws `CDRSerializationError.stringTooLong`, and decoding one throws
  `CDRDecodingError.boundedStringTooLong`. Regenerate your own types to get the checks.
- **`wstring` is rejected by the generator.** `swift-ros2-gen` used to emit a `wstring` field as a
  UTF-8 string, which no RMW decodes. It now fails with `<file>:<line>: wstring is not supported
  yet` for any field that is, or holds, a `wstring`.
- **`wireMode` takes precedence over `distro`, and a mismatch is logged.** `ROS2Context(distro:)`
  names the host's distribution (default `.jazzy`) and is the default for
  `TransportConfig.wireMode`. An explicit `wireMode` (`.zenoh(locator:wireMode:)`) overrides
  `distro` for the wire format of the session: the Zenoh key expressions and liveliness tokens
  and the layout of the wire DDS `ros_discovery_info` record. `distro` still decides the type
  hash and schema handling of the entities (for example `sensor_msgs/Range.variance`). Both
  stay public and unchanged; what is new is that a context created with a `wireMode` that
  differs from `distro` logs one warning (the unified log on Apple platforms, standard error
  elsewhere) instead of silently mixing the two. Pass the host's distribution as `distro`
  and leave `wireMode` unset, or pass the same value to both.

### Changes on the wire

These change what ROS 2 tools on the host see; topic, service and action data keep flowing as
before.

- **Wire Zenoh topics belong to their node.** Publishers and subscriptions used to be announced
  under a made-up node `ios_<topic>_node` in `/`, one per topic, so `ros2 node list` showed one
  fake node per topic and `ros2 node info` listed no topics for the real node. They are now
  announced under the `ROS2Node` that created them, as services and actions already were, and
  each node declares its own node token, so a destroyed node leaves the host's graph at once
  instead of when the session closes. A subscription is announced on every distribution, not
  only on Lyrical and later.
- **Each wire Zenoh publisher and client has its own GID.** Every topic publisher of a session
  used to send one shared GID that matched nothing in the ROS graph, and service and action
  clients sent a random one. Each publisher (including an action server's feedback and status
  publishers), service client and action client now sends the GID rmw_zenoh_cpp gives an
  entity, the XXH3 128-bit hash of its liveliness token. The GID in `ros2 topic info -v` matches
  the one in every sample, and a subscriber's per-publisher state (`message_lost`,
  `publisher_gid`) tells two Swift publishers apart.
- **Hashless wire Zenoh topics are keyed like services on Jazzy and later.** A topic whose type
  has no type hash was keyed `…/<Type>_/TypeHashNotSupported`; it now omits the hash segment, as
  services and action topics already did. Humble keeps the `TypeHashNotSupported` segment.
  Generated and built-in types all carry a hash, so their keys do not change.
- **Wire DDS nodes appear in the ROS graph.** The wire DDS transport (`.ddsMulticast` /
  `.ddsUnicast`) now publishes `ros_discovery_info`, the record an `rmw_cyclonedds_cpp` host
  uses to tie readers and writers to nodes. `ros2 node list` and `ros2 node info` show the Swift
  node, `ros2 param` finds it, and `ros2 topic info -v` names it instead of
  `_NODE_NAME_UNKNOWN_`. The record's GID layout follows the context's `distro` (24 bytes on
  Humble, 16 from Iron on), so pass the host's distribution to `ROS2Context`; an explicit
  `TransportConfig.wireMode` takes precedence over `distro` here (see "Behavior changes").

## Compatibility table

| From | To | Breaking changes |
|---|---|---|
| 0.6.0 | 0.6.1 | **One:** the placeholder `ROS2Service` protocol in `SwiftROS2Messages` was renamed to `ROS2ServiceType` so the umbrella's typed Service Server class can take the simpler `ROS2Service<S>` name in 0.7.0. |
| 0.6.x | 0.7.x | **One** if upgrading from 0.6.0 directly: the rename above. From 0.6.1 → 0.7.x there are no breaking changes — the Services API is purely additive. |
| 0.7.x | 0.8.0 | **None.** Actions are purely additive — `ROS2Action`, `ROS2ActionServer`, `ROS2ActionClient`, `ActionGoalHandle`, `ActionResult`, `ActionGoalStatus`, `ActionError` are new. `ROS2ActionTypeInfo` gained five optional hash fields with source-compatible defaults (Phase 1). |
| 0.8.x | 0.9.0 | **None.** `swift-ros2-gen` (CLI + SwiftPM build plugin + hash-oracle CI) is purely additive — no existing public API changed. |
| 0.9.x | 1.0.0 | **Six visibility-only changes** — plumbing types pulled out of the public surface (`TransportQoS`, `QoSPolicy`, `DDSBridge*`, `ZenohClientProtocol`/`DDSClientProtocol` + 10 related, `EntityManager`/`GIDManager` → `package`; `ZenohTransportPublisher`, `DeclaredKeyExpr`/`ZenohSubscriber`/`LivelinessToken` → `internal`). End-user APIs (`ROS2Context`, `ROS2Node`, `ROS2Publisher`, `ROS2Subscription`, `ROS2Service`, `ROS2Client`, `ROS2ActionServer`, `ROS2ActionClient`, `QoSProfile`, `TransportConfig`, all message types) are unchanged. |
| 1.0.x | 1.x   | **None guaranteed.** Minor releases on the 1.x line will not break public API (no symbol was removed or changed; 1.3.0's new `TransportType.rcl` case does break exhaustive `switch` statements — see the 1.2.x → 1.3.0 row). |
| 1.0.x | 1.1.0 | **None.** Parameter API (`ROS2Node.declareParameter` / `setParameter` / `setOnSetParametersCallback` / six standard parameter services / `/parameter_events` publisher / `ROS2ParameterClient`) is purely additive. |
| 1.1.x | 1.2.0 | **None.** The `ROS2Publisher.publish(_:timestamp:sequenceNumber:)` source-timestamp overload is purely additive — the existing `publish(_:)` is unchanged (it now delegates to the overload with the same wall-clock timestamp + monotonic sequence). |
| 1.2.x | 1.3.0 | **One, source-level:** `TransportType` gained a `.rcl` case (#120), so exhaustive `switch` statements over `TransportType` need a `.rcl` case, and `TransportType.allCases` now includes it. Everything else is additive — the RCL backend is opt-in via `SWIFT_ROS2_ENABLE_RCL=1` at this tag. |
| 1.3.x | 1.4.0 | **None.** Additive: umbrella on Android/DDS-less Windows; RCL default-on and the wire-client deprecation warnings first reach tagged consumers here. |
| 1.4.x | 2.0.0 | **Yes.** Wire clients removed from the public API. On the pure-Swift wire transports, the action frame layout and the DDS service request header (24 → 16 bytes) changed, so 1.x wire peers do not interoperate with 2.0 for actions or DDS services (including the DDS-wire parameter services); 1.x peers on the RCL backend are unaffected (see below). |
| 2.0.x | 2.1.0 | **One, source-level:** `ROS2Distro` gained a `.lyrical` case (ROS 2 Lyrical Luth), so exhaustive `switch` statements over `ROS2Distro` need a `.lyrical` case or a `default`, and `ROS2Distro.allCases` now includes it. New distributions ship in minors by policy — see "2.0 → 2.1". |
| 2.1.x | 2.2.0 | **None.** The Apple RCL xcframeworks are rebuilt from ROS 2 Lyrical and renamed `CRos2` / `CRos2Zenoh`. They are binary targets, not products, and nothing imports them. In the default Apple graph (cyclonedds RCL variant), `.dds` now runs on the CycloneDDS 11.0.1 inside `CRos2` instead of the bundled 0.10.5 fork. |
| 2.2.x | 2.3.0 | **None.** Additive: `ROS2Publisher.hasMatchedSubscriptions` and `onMatchedSubscriptionsChanged(_:)` are new, and TRANSIENT_LOCAL is now served on wire Zenoh. The vendored zenoh-pico moves to 1.7.1; wire Zenoh now declares a publisher per topic; volatile publishers still deliver with `z_put` on the declared key expression, and TRANSIENT_LOCAL publishers put through zenoh-pico's advanced publisher. See "2.2 → 2.3". |
| 2.3.0 | 2.3.1 | **None.** No code change is needed. One behavior change on wire Zenoh: publishing on a session that lost its router now throws `TransportError.sessionUnhealthy` (it was `.publishFailed` for plain publishers and a silent success for TRANSIENT_LOCAL ones); both are recoverable. See "2.3.0 → 2.3.1". |
| 2.3.1 | 2.3.2 | **None.** No code change is needed. `ROS2Context.shutdown()`, `ROS2Node.destroy()` and `ROS2ParameterClient.close()` run their blocking closes on a per-context serial queue instead of the cooperative pool; the teardowns of one context now run one at a time. See "2.3.1 → 2.3.2". |
| 2.3.x | 3.0.0 | **Yes.** The package moves to `swift-ros2/swift-ros2` and splits in three: the standard message types, the generator and the CDR codec leave. Add swift-ros2-common-interfaces for message types; `Range` is `RangeMsg`; `AudioData` and the generator products are gone from swift-ros2. See "2.x → 3.0" at the top of this file. |

SwiftROS2 follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once 1.0.0 is cut. Breaking changes after 1.0 require a major bump.

---

## 0.6.0 → 0.6.1 / 0.7.0 — `ROS2Service` placeholder rename

The 0.6.0 line shipped a placeholder protocol named `ROS2Service` in `SwiftROS2Messages` (with no implementation). To make room for the typed Service Server class `ROS2Service<S>` in `SwiftROS2`, that placeholder was renamed to `ROS2ServiceType` in 0.6.1.

If your code conformed to the old name:

```swift
// before (0.6.0)
public enum MySrv: ROS2Service { ... }

// after (0.6.1+)
public enum MySrv: ROS2ServiceType { ... }
```

The shape of the protocol is unchanged — same `Request` / `Response` associated types, same `static var typeInfo: ROS2ServiceTypeInfo` requirement. The only thing that moved is the name. Conduit's `BuiltinServices/StdSrvs/Trigger.swift` was already on the new name; downstreams that referenced the placeholder need this one-line rename.

## 0.x → 0.7 — no breaking changes (other than the rename above)

0.7.x adds:
- **Services** (typed `ROS2Service<S>` / `ROS2Client<S>` over both Zenoh and DDS), `ServiceError`, `ROS2Node.createService` / `createClient`. New, additive — no existing API renamed or removed.
- DocC catalog and richer `///` comments.
- Per-target line-coverage gate in CI.
- `swift package diagnose-api-breaking-changes` on every PR.
- Internal refactors of the transport sessions (now also walk service servers / clients in `close()`).

No public type, function, protocol, or property already shipping in 0.6.1 is renamed, removed, or made `internal` in 0.7.x.

---

## 0.7 → 0.8 — Actions

0.8.0 ships the ROS 2 Actions umbrella — six PRs, every one of them additive. No existing public symbol was renamed, removed, or had its shape changed.

### Adding action support to existing code

If you have a Conduit-style app that already calls `node.createPublisher` / `createService`, the action surface follows the same pattern:

```swift
let server = try await node.createActionServer(
    FibonacciAction.self,
    name: "/fibonacci",
    handler: MyHandler()  // an actor conforming to ActionServerHandler
)

let client = try await node.createActionClient(FibonacciAction.self, name: "/fibonacci")
try await client.waitForActionServer(timeout: .seconds(5))
let handle = try await client.sendGoal(FibonacciAction.Goal(order: 10))
let result = try await handle.result()
```

See the `Actions.md` DocC chapter for the full walk-through.

### `ROS2ActionTypeInfo`

The struct gained five optional `*TypeHash` fields for the synthesized wrapper messages, set through a new 8-hash initializer. The 3-hash initializer `ROS2ActionTypeInfo(actionName:goalTypeHash:resultTypeHash:feedbackTypeHash:)` stayed through 2.x; swift-ros2-rosidl 1.0.0, which swift-ros2 3.0 depends on, removes it (see "2.x → 3.0").

### Per-role QoS

`QoSProfile.actionDefault` is the new default for `createActionServer` / `createActionClient`. The transport layer applies a `transient_local / depth 1` override on the `_action/status` topic automatically.

### Naming note: `ActionGoalStatus` vs `GoalStatus`

The umbrella exposes ``ActionGoalStatus`` (an `Int8`-backed enum) for the status surface returned by `ActionResult` / `handle.statusUpdates`. The wire-level `GoalStatus` struct (the embedded CDR payload of `GoalStatusArray`) ships in `SwiftROS2Messages` and re-exports through the umbrella, so both names are visible — they are intentionally different shapes for different layers.

---

## 0.8 → 0.9 — `swift-ros2-gen`

0.9.0 ships the `swift-ros2-gen` code generator end-to-end: CLI (with `.msg` / `.srv` / `.action` support and multi-distro merging), a single-distro `.msg`-only SwiftPM build plugin, and a `verify-hash-oracle` CI job. Every change is additive — no existing public symbol was renamed, removed, or had its shape changed.

### Adding code generation to a downstream Apple project

> Historical: the generator and the build plugin moved to
> [swift-ros2-rosidl](https://github.com/swift-ros2/swift-ros2-rosidl) in 3.0, and the snippet
> below is the 3.0 form. A 0.9-era `package: "swift-ros2"` plugin reference no longer resolves.

```swift
// Package.swift — opt the target into the SwiftROS2GenPlugin build plugin
dependencies: [
    .package(url: "https://github.com/swift-ros2/swift-ros2.git", from: "3.0.0"),
    .package(url: "https://github.com/swift-ros2/swift-ros2-rosidl.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "my_msgs",  // snake_case / lowercase — becomes the ROS package segment in typeInfo.typeName
        dependencies: [
            .product(name: "SwiftROS2", package: "swift-ros2"),
        ],
        exclude: ["msg"],  // the plugin reads msg/; SwiftPM must not treat it as unhandled files
        plugins: [
            .plugin(name: "SwiftROS2GenPlugin", package: "swift-ros2-rosidl"),
        ]
    ),
]
```

There is no configuration file. Drop the `.msg` files into the target's directory under `msg/` and build — the plugin walks `msg/` directly, hands every file to `swift-ros2-gen` with `<target-name>=<dir>@jazzy`, and writes the generated Swift under SwiftPM's per-target work directory.

The plugin handles only the single-package single-distro (jazzy) `.msg` case. `.srv` and `.action` files in the target directory are skipped with a build warning, and SwiftPM also warns about the unhandled files unless the `srv` and `action` directories are listed in the target's `exclude:`. For multi-distro merging, multi-package builds, `.srv`, `.action`, or an explicit `--types` allow-list, invoke `swift run swift-ros2-gen` directly (see the [swift-ros2-rosidl README](https://github.com/swift-ros2/swift-ros2-rosidl#generating-a-type-package)). A working setup lives at [`Sources/Examples/PluginSmoke/`](https://github.com/swift-ros2/swift-ros2-rosidl/tree/1.0.0/Sources/Examples/PluginSmoke) in swift-ros2-rosidl.

### Verifying type hashes against a live ROS 2 install

> Historical: swift-ros2 no longer vendors ROS IDL, so the `vendor/...` input paths below do not
> exist in 3.x. The verification now runs in swift-ros2-rosidl and in each interface repository;
> see "Interface repositories and the oracles" in the
> [swift-ros2-rosidl README](https://github.com/swift-ros2/swift-ros2-rosidl#interface-repositories-and-the-oracles).

`--verify-hashes` takes a Docker image as its argument value (the verifier shells into the image and reads canonical `share/<pkg>/{msg,srv,action}/<Type>.json` files). The verifier resolves nested-type references, so every transitively-referenced package must appear on `--input`. In 0.9 the invocation was:

```bash
swift run swift-ros2-gen --verify-hashes osrf/ros:jazzy-desktop \
    --input "builtin_interfaces=vendor/rcl_interfaces-jazzy/builtin_interfaces@jazzy" \
    --input "std_msgs=vendor/common_interfaces-jazzy/std_msgs@jazzy" \
    --input "geometry_msgs=vendor/common_interfaces-jazzy/geometry_msgs@jazzy" \
    --input "sensor_msgs=vendor/common_interfaces-jazzy/sensor_msgs@jazzy"
```

Diffs each generated `RIHS01_*` against the canonical rosidl JSON inside the named Docker image — there is no recorded baseline shipped in the package. The matching CI job was `verify-hash-oracle` in `hash-oracle.yml`; it is now the reusable workflow [`interface-oracles.yml`](https://github.com/swift-ros2/swift-ros2-rosidl/blob/1.0.0/.github/workflows/interface-oracles.yml) in swift-ros2-rosidl, which swift-ros2-common-interfaces calls too.

---

## 0.9 → 1.0 — actual change list

### Candidate 1 — `TransportQoS` and `QoSPolicy`

- **Location at 0.9:** `Sources/SwiftROS2Transport/TransportSession.swift` (`TransportQoS`); `Sources/SwiftROS2Wire/WireCodec.swift` (`QoSPolicy`).
- **Declaration at 0.9:** `public struct TransportQoS`, `public struct QoSPolicy`.
- **1.0 change:** demoted to `package` (Swift 5.9+ access modifier — invisible to downstream consumers, still reachable from the other targets and tests in this SPM package).
- **Rationale:** both are derived representations of `QoSProfile`. End users do not need to construct them directly. Three parallel public QoS types (profile / transport / wire) inflate the API surface for no functional gain.
- **Replacement:** `QoSProfile` (presets `.default`, `.sensorData`, `.reliableSensor`, `.latched`, `.servicesDefault`, or `init(reliability:durability:history:)`).
- **Impact surface:** code that constructs `TransportQoS(...)` or `QoSPolicy(...)` directly. Detect with `grep -rn "TransportQoS(\|QoSPolicy(" your-project/`.
- **Recommended action:** replace direct construction with `QoSProfile(...)`.

### Candidate 2 — `DDSBridgeQoSConfig`, `DDSBridgeDiscoveryConfig`, `DDSBridgeDiscoveryMode`

- **Location at 0.9:** `Sources/SwiftROS2Transport/DDSClientProtocol.swift`.
- **Declaration at 0.9:** `public struct DDSBridgeQoSConfig`, `public struct DDSBridgeDiscoveryConfig`, `public enum DDSBridgeDiscoveryMode`.
- **1.0 change:** demoted to `package` (Swift 5.9+ access modifier — invisible to downstream consumers, still reachable from the other targets and tests in this SPM package).
- **Rationale:** these types only exist in the public API to appear in `DDSClientProtocol` parameters. `DDSBridgeDiscoveryMode` (Int32-raw) duplicates `TransportConfig.DDSDiscoveryMode` (String-raw) at the concept level.
- **Replacement:** `TransportConfig.DDSDiscoveryMode` and `DDSPeer` continue to be the public configuration surface.
- **Impact surface:** code that constructs `DDSBridgeQoSConfig(...)` or `DDSBridgeDiscoveryConfig(...)` directly. Grep for `DDSBridge`.
- **Recommended action:** replace direct construction with `TransportConfig.ddsMulticast(...)` / `TransportConfig.ddsUnicast(...)`.

### Candidate 3 — `ZenohClientProtocol`, `DDSClientProtocol`, and related public types

- **Related types (10):** `ZenohKeyExprHandle`, `ZenohSubscriberHandle`, `ZenohLivelinessTokenHandle`, `ZenohQueryableHandle`, `ZenohQueryHandle`, `ZenohSample`, `ZenohError`, `DDSWriterHandle`, `DDSReaderHandle`, `DDSError`.
- **Location at 0.9:** `Sources/SwiftROS2Transport/{Zenoh,DDS}ClientProtocol.swift`.
- **1.0 change:** demoted to `package` (Swift 5.9+ access modifier — invisible to downstream consumers, still reachable from the other targets and tests in this SPM package).
- **Rationale:** these protocols exist so consumers can wrap the C bridge themselves and inject a custom client. In practice every known consumer uses the stock `ZenohClient()` / `DDSClient()` from `SwiftROS2Zenoh` / `SwiftROS2DDS` directly — both remain `public`. The implementation-injection seam is over-budget for the 1.0 freeze. As a knock-on effect, the cross-target plumbing that referenced these protocol types — `TransportSession` / `TransportPublisher` / `TransportSubscriber`, the `ROS2Context.init(... session:)` 4-arg initializer, and `*TransportSession` initializers — was demoted to `package` as well, since a `public` API can't take a `package` type as a parameter.
- **Replacement:** the high-level public API. Construct a context with `ROS2Context(transport: TransportConfig)` (which now picks the correct stock `ZenohClient` / `DDSClient` internally based on `TransportConfig.type`); use `ROS2Publisher` / `ROS2Subscription` / `ROS2Service` / `ROS2Client` / `ROS2ActionServer` / `ROS2ActionClient` from `node.create*`. The injection seam (`session:`-shaped initializers, `TransportSession` / `TransportPublisher` / `TransportSubscriber` protocols) is no longer reachable from outside the package.
- **Impact surface:** code that conforms to `ZenohClientProtocol` / `DDSClientProtocol` (custom wrappers), constructs a `*TransportSession` directly, or holds `any TransportPublisher` / `any TransportSubscriber`. Grep for `: ZenohClientProtocol\|: DDSClientProtocol\|TransportSession(\|any TransportPublisher\|any TransportSubscriber`.
- **Recommended action:** drop the custom conformance / direct session construction and use `ROS2Context(transport:)` plus `node.createPublisher(...)` / `createSubscription(...)` / `createService(...)` / etc.

### Candidate 4 — `EntityManager`, `GIDManager`

- **Location at 0.9:** `Sources/SwiftROS2Transport/{EntityManager,GIDManager}.swift`.
- **Declaration at 0.9:** `public final class`.
- **1.0 change:** demoted to `package` (Swift 5.9+ access modifier — invisible to downstream consumers, still reachable from the other targets and tests in this SPM package).
- **Rationale:** library-internal entity-id allocator and GID storage. No external construction required.
- **Replacement:** none required (`ROS2Context` and `ROS2Node` own these internally).
- **Impact surface:** code that constructs `EntityManager()` or `GIDManager()` directly.
- **Recommended action:** drop direct instantiation.

### Candidate 5 — `ZenohTransportPublisher` (concrete class)

- **Location at 0.9:** `Sources/SwiftROS2Transport/ZenohTransportSession+Publisher.swift`.
- **Declaration at 0.9:** `public final class ZenohTransportPublisher: TransportPublisher`.
- **1.0 change:** demoted to `internal` (no cross-target references, so plain `internal` suffices).
- **Rationale:** the protocol `TransportPublisher` already exists, and the umbrella's `ROS2Publisher` is the supported public type that wraps it; the concrete Zenoh class never needed to be public.
- **Replacement:** the umbrella's public `ROS2Publisher`, returned by `node.createPublisher(...)`. The `TransportPublisher` protocol itself was also demoted to `package` (knock-on from Candidate 3) — downstream code can't name it from outside the SPM package.
- **Impact surface:** code that names `ZenohTransportPublisher` directly (e.g. as a stored type), or that holds `any TransportPublisher` from outside the package.
- **Recommended action:** replace with `ROS2Publisher` from `node.createPublisher(...)`.

### Candidate 6 — `DeclaredKeyExpr`, `ZenohSubscriber`, `LivelinessToken`

- **Location at 0.9:** `Sources/SwiftROS2Zenoh/ZenohClient.swift`.
- **1.0 change:** demoted to `internal` (no cross-target references, so plain `internal` suffices).
- **Rationale:** internal concrete classes of `ZenohClient`. They should be accessed only through the corresponding handle protocols.
- **Replacement:** `ZenohKeyExprHandle`, `ZenohSubscriberHandle`, `ZenohLivelinessTokenHandle` (which were themselves demoted to `package` in Candidate 3).
- **Impact surface:** code that names these classes directly.
- **Recommended action:** drop direct references.

> **Note:** the analogous Service placeholders (`ROS2ServiceTypeInfo`, `ROS2ServiceType`) were retained in 0.7.0 once the typed `ROS2Service<S>` / `ROS2Client<S>` umbrella landed — they are now real, implemented protocols, not placeholders.

---

## 1.0 → 1.x compatibility contract

After 1.0, no minor or patch release on the 1.x line will break the public API. Breaking changes require a major bump (2.0). The one source-level exception on the 1.x line is 1.3.0's new `TransportType.rcl` case, which breaks exhaustive `switch` statements over `TransportType` (see "1.2 → 1.3").

---

## 1.0 → 1.1 — Parameter API

1.1.0 adds the ROS 2 Parameter API. Every existing 1.0.x symbol is unchanged; this section is just a tour of what's new so downstreams can adopt incrementally.

### New Swift-public types

- `ROS2ParameterValue` — sum type over the nine wire slots + `.notSet`.
- `ROS2Parameter` — `name` + `value` pair.
- `ROS2ParameterType` — Swift enum mirroring the wire `uint8` constants.
- `ROS2ParameterDescriptor` — name, type, description, ranges, read-only / dynamic-typing flags.
- `ROS2SetParametersResult`, `ROS2ListParametersResult` — Swift twins of the wire result structs.
- `ROS2ParameterError` — typed errors for the throwing parameter APIs.
- `ROS2ParameterCallbackHandle` — opaque token; keep it alive for the callback to remain active.
- `ROS2ParameterClient` — high-level remote-node client.
- `ROS2NodeOptions` — per-node creation toggles, currently `startParameterServices: Bool` (default `true`).
- `QoSProfile.parameterEvents` — preset matching `rmw_qos_profile_parameter_events`.

### New methods on `ROS2Node`

```swift
extension ROS2Node {
    func declareParameter<T: ROS2ParameterConvertible>(_ name: String, default: T, descriptor: ROS2ParameterDescriptor) async throws -> T
    func undeclareParameter(_ name: String) async throws
    func hasParameter(_ name: String) async -> Bool
    func listParameters(prefixes: [String], depth: UInt64) async -> ROS2ListParametersResult
    func getParameter(_ name: String) async throws -> ROS2Parameter
    func getParameterOrDefault<T: ROS2ParameterConvertible>(_ name: String, default: T) async -> T
    func setParameter(_: ROS2Parameter) async -> ROS2SetParametersResult
    func setParameters(_: [ROS2Parameter]) async -> [ROS2SetParametersResult]
    func setParametersAtomically(_: [ROS2Parameter]) async -> ROS2SetParametersResult
    func describeParameter(_ name: String) async throws -> ROS2ParameterDescriptor
    func setPreSetParametersCallback(_:) async -> ROS2ParameterCallbackHandle
    func setOnSetParametersCallback(_:) async -> ROS2ParameterCallbackHandle
    func setPostSetParametersCallback(_:) async -> ROS2ParameterCallbackHandle
    func removeParameterCallback(_:) async -> Bool
    func createParameterClient(remoteNode: String, defaultTimeout: Duration) async throws -> ROS2ParameterClient
}
```

### Adopting

No code change is required to upgrade — `Context.createNode(...)` keeps its old signature and now also auto-registers the six parameter services (opt out via `ROS2NodeOptions(startParameterServices: false)` if you don't need them).

## 1.2 → 1.3 — RCL everywhere

1.3.0 completes the native RCL backend on every platform it can currently
reach: Apple (prebuilt `CRos2Jazzy` / `CRos2JazzyZenoh` xcframeworks, one rmw
baked per build variant) and Linux (system ROS 2 install via
`ROS2_RCL_PREFIX`, rmw selected at runtime from the transport type). No existing
public symbol was removed or changed, but the release is not purely additive at the
source level: `TransportType` gained a `.rcl` case (#120), so an exhaustive `switch`
over `TransportType` needs a `.rcl` case, and `TransportType.allCases` includes it
even on build graphs where `ROS2Context` throws `TransportError.unsupportedFeature`
for it (filter it out of transport pickers there). RCL is opt-in via
`SWIFT_ROS2_ENABLE_RCL=1` on every platform at this tag, including Apple.

> **Tag note:** the wire-client deprecation below and the RCL-default-on flip
> for Apple were merged on `main` after the `1.3.0` tag (`ed83b5527`) was cut.
> Consumers pinned to a tag see both for the first time in `1.4.0` — see the
> "1.3 → 1.4 — the bridge to 2.0" section below.

### What is deprecated

Constructing the wire clients directly:

```swift
import SwiftROS2Zenoh
let client = ZenohClient()   // warning: deprecated, removed from the public API in 2.0.0

import SwiftROS2DDS
let dds = DDSClient()        // warning: deprecated, removed from the public API in 2.0.0
```

### What is NOT deprecated

The umbrella API — it is backend-agnostic; the build graph decides which backend
serves each transport type (see the routing table in the README's "Backends" section):

```swift
let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/192.168.1.85:7447"))
let node = try await ctx.createNode(name: "talker")
```

If you construct `ZenohClient` / `DDSClient` only to hand them to
`ROS2Context`, drop the explicit construction and let `ROS2Context` pick the
backend. If you use the wire clients standalone (raw key-expression puts,
wire-level subscribers), plan the move to the umbrella API before 2.0.0 —
2.0.0 removes the wire clients from the public API; the wire runtime remains
the internal fallback where RCL is not available and is retired per platform
in 2.x minors, non-breaking. The CDR / wire codecs survive as the golden-byte
correctness fixtures either way.

### Per-variant nuance

- Apple zenoh-rmw RCL variant (`SWIFT_ROS2_RCL_RMW=zenoh`): the zenoh wire
  family is *physically absent* from the build graph (symbol collision with
  the bundled zenoh-c), so `ZenohClient` does not exist there at all.
- Linux RCL builds: both backends stay linked (no symbol collision — rmw is a
  dlopen'd plugin); RCL is preferred at runtime for `.zenoh` and `.dds`.
- Apple default graph (RCL on, `cyclonedds` rmw): `.zenoh` and `.dds*` still run
  on the wire path; only `.rcl` / `.rclUnicast` reach RCL.
- Android, Windows: the wire path remains the automatic fallback until an RCL
  path exists for them. The zenoh-rmw variant ships no visionOS slice, so on
  visionOS `.zenoh` stays on the wire path (default graph).

## 1.3 → 1.4 — the bridge to 2.0

Tag `1.3.0` predates the deprecation annotations and the RCL-default-on pin; consumers
pinned to a tag see both for the first time in 1.4.0. 2.0.0 removes the wire clients
from the public API; the wire runtime remains the internal fallback where RCL is not
available and is retired per platform in 2.x minors, non-breaking.

### Android / DDS-less Windows: move from `ZenohClient` to the umbrella

1.4.0 builds the `SwiftROS2` umbrella on every platform. Replace direct wire-client use:

```swift
// before (deprecated; removed from the public API in 2.0.0)
import SwiftROS2Zenoh
let client = ZenohClient()
try client.open(locator: "tcp/192.168.1.85:7447")

// after
import SwiftROS2
let ctx = try await ROS2Context(transport: .zenoh(locator: "tcp/192.168.1.85:7447"))
let node = try await ctx.createNode(name: "talker")
```

`.dds` transports throw `TransportError.unsupportedFeature` where CycloneDDS is not part of the build.

## 1.x → 2.0 — the wire clients leave the public API

2.0.0 removes the wire clients from the public API; the wire runtime remains the internal
fallback where RCL is not available and is retired per platform in 2.x minors, non-breaking.

**Removed:** products `SwiftROS2Zenoh`, `SwiftROS2DDS`; public types `ZenohClient`,
`ZenohQueryable`, `DDSClient`, `ZenohTransportSession`, `DDSTransportSession`, `RMWRequestId`.

**Upgrading from 1.2 or earlier** — 2.0.0 also carries the 1.3.0 and 1.4.0 changes (items 2–4 apply to every 1.x consumer):

1. **`TransportType.rcl`** (added in 1.3.0). Exhaustive `switch` statements over
   `TransportType` need a `.rcl` case. `TransportType.allCases` includes `.rcl` even on
   build graphs where `ROS2Context` throws `TransportError.unsupportedFeature` for it
   (see the routing table in the README's "Backends" section) — filter it out of
   transport pickers there.
2. **Drop the wire products.** Remove the `SwiftROS2Zenoh` / `SwiftROS2DDS` product
   dependencies and replace those imports with `import SwiftROS2`. A stale
   `import SwiftROS2Zenoh` may still compile, because SwiftPM builds the target for the
   umbrella, but it declares no public API of its own (it only re-exports
   `SwiftROS2Transport`, which `SwiftROS2` re-exports too) and is not a supported import.
3. **Bump the requirement** to `from: "2.0.0"`.
4. **RCL on Apple is on by default** (since 1.4.0): the prebuilt `CRos2Jazzy`
   xcframework is downloaded and linked, so the binary grows. Opt out with
   `SWIFT_ROS2_DISABLE_RCL=1`; for Xcode it must be set in the environment Xcode resolves
   packages with (not in a scheme or build setting).

**Replace a connectivity probe**

```swift
// 1.x
let client = ZenohClient(); try client.open(locator: locator); try client.close()
// 2.0
let ctx = try await ROS2Context(transport: .zenoh(locator: locator)); await ctx.shutdown()
```

This is a reachability probe only where `.zenoh` resolves to the wire client. On the
RCL-zenoh builds (the Apple zenoh-rmw variant and Linux with `SWIFT_ROS2_ENABLE_RCL=1`)
context creation does not block on the router — `rmw_zenoh` continues in peer mode — so
the probe reports success without a router.

**Replace raw puts / wire-level subscribers** with `node.createPublisher` /
`node.createSubscription`. The CDR and wire codecs (`SwiftROS2CDR`, `SwiftROS2Wire`) stay public.

**Action and DDS service wire format.** On the pure-Swift wire transports, 1.x spliced a
second CDR encapsulation header into action goal / feedback / result frames (DDS and
Zenoh) and prefixed DDS service requests and replies with a 24-byte request identity. Two
1.x wire peers cancelled both out; real ROS 2 nodes read them as data. 2.0 emits the
upstream layout — a single encapsulation header, and `rmw_cyclonedds_cpp`'s 16-byte
request header — so **a 1.x peer on a wire transport does not interoperate with a 2.0
peer for actions or DDS services** (the DDS-wire parameter services included) — upgrade
both sides. A 1.x peer on the RCL backend
(e.g. `.rcl`) already emitted the upstream layout through rmw and interoperates with 2.0
unchanged. Topics and Zenoh services are unaffected.

## 2.0 → 2.1 — ROS 2 Lyrical Luth

`ROS2Distro.lyrical` joins the modern wire group (RIHS01 type hash, the same
key expressions as Jazzy, `isLegacySchema == false`). `ROS2Context`'s default
distro stays `.jazzy`; pass `distro: .lyrical` to label a Lyrical host
explicitly.

**Distribution policy.** ROS 2 ships a new distribution every May. swift-ros2
adds the matching `ROS2Distro` case in a minor release rather than a major
one, the same way 1.3.0 added `TransportType.rcl`. Code that switches over
`ROS2Distro` should include a `default` branch so a new distribution does
not break the build:

    switch distro {
    case .humble: legacyPath()
    default: modernPath()
    }

## 2.2 → 2.3 — matched subscriptions and latched topics on wire Zenoh

2.3.0 is additive. No existing symbol changed, and no code needs to change.

**New: `ROS2Publisher.hasMatchedSubscriptions` and `onMatchedSubscriptionsChanged(_:)`.**
A publisher can tell whether at least one subscription matches it, so a
producer can skip expensive work (encoding an image, reading a sensor) while
nobody listens. The property is `true` while a subscription matches. The
handler is called once with the current state before the method returns, then
on every change; the state is sampled every 50 ms. The behavior is the same
on Zenoh, DDS and RCL. A transport that cannot tell reports `true`, so code that
skips work without subscribers never stops publishing by mistake.

    let pub = try await node.createPublisher(CompressedImage.self, topic: "camera/image/compressed")
    pub.onMatchedSubscriptionsChanged { [weak pub] matched in
        guard let pub else { return }
        print("\(pub.topic):", matched ? "someone is listening" : "no subscribers")
    }

On Zenoh the state follows the router's report of matching subscribers, so it
can read `false` for a short time after the publisher is created. Delivery is
unaffected: a publish with no matching subscriber is sent as before.

**Wire Zenoh declares a publisher per topic.** It reads the publisher's
matching status. Volatile publishers still deliver with `z_put` on the declared
key expression, so the first message after a publisher is created is not
dropped; TRANSIENT_LOCAL publishers put through zenoh-pico's advanced
publisher (see below). The wire format is unchanged.

**TRANSIENT_LOCAL is served on wire Zenoh.** A publisher created with
`durability: .transientLocal` is declared as a zenoh-pico advanced publisher
with rmw_zenoh's options (a cache of the history depth, publisher detection,
500 ms sporadic heartbeats when reliable). An rmw_zenoh subscriber that joins
later, such as `ros2 topic echo --qos-durability transient_local`, receives
the cached samples. Swift subscribers on wire Zenoh do not fetch the cache:
they receive the samples published after they subscribe. Builds without
advanced publication fall back to a plain publisher. The `latched-talker`
example shows the late-joiner flow.

**zenoh-pico 1.7.1.** The vendored zenoh-pico moves from 1.1.0 to 1.7.1, and
the `CZenohPico` xcframework is rebuilt from it. The wire format toward
`rmw_zenoh_cpp` is unchanged. Auto-reconnect stays disabled, as in 1.1.0;
swift-ros2 reconnects by opening a new session. `SWIFT_ROS2_ZENOH_LOCAL=1`
resolves `CZenohPico` from `build/zenoh-pico/` for local development.

## 2.3.0 → 2.3.1 — wire Zenoh after a router loss

2.3.1 is a patch release. No symbol changed, and no code needs to change.

**Behavior change: publishing on a wire Zenoh session that lost its router
throws `TransportError.sessionUnhealthy`.** zenoh-pico keeps a client session
open after its router stops answering (auto-reconnect is off), and 2.3.0
reported such a session as healthy. Now `ROS2Context.isConnected` is `false`
and `publish` throws `TransportError.sessionUnhealthy`. Before, a plain
publisher threw `TransportError.publishFailed`, and a TRANSIENT_LOCAL publisher
cached the sample and reported success. Both errors are recoverable
(`isRecoverable` is `true`), so callers that switch on the exact case should
handle `.sessionUnhealthy`:

    do {
        try pub.publish(message)
    } catch TransportError.sessionUnhealthy {
        // The router is gone: shut the context down and open a new one.
    } catch TransportError.publishFailed {
        // A single put failed on a live session.
    }

zenoh-pico notices the loss when the router's lease expires, one to two leases
after the router goes silent: 60 to 120 s with `rmw_zenohd`'s 60 s lease.

**Matched subscriptions report unknown on such a session.**
`hasMatchedSubscriptions` is `true` and `onMatchedSubscriptionsChanged` reports
`true`, so code that publishes only while someone listens keeps publishing,
sees the error above and can reconnect. In 2.3.0 the last state seen stuck,
and a topic without subscribers read `false` forever.

**Closing a session after the loss is detected no longer crashes** (a crash
present in 2.3.0). `ROS2Context.shutdown()`, and with it a reconnect,
completes. The bridge frees swift-ros2's own handles and leaves the zenoh-pico
state allocated: a bounded leak per lost router, which includes TRANSIENT_LOCAL
publisher caches up to their history depth. Creating publishers, subscriptions,
services or actions on such a session throws `TransportError.notConnected`. A
transport that fails during a call, and zenoh-pico's heartbeat for
TRANSIENT_LOCAL publishers, can still crash; see #214 for the remaining
limitations.

**The binary targets stay on the 2.3.0 assets.** `Package.swift` keeps the
2.3.0 `binaryTarget` URLs and checksums, because 2.3.1 changes only
source-built code.

## 2.3.1 → 2.3.2 — teardown off the cooperative pool

2.3.2 is a patch release. No symbol changed, and no code needs to change.

**Teardown no longer holds a cooperative-pool thread while a close blocks.**
`ROS2Context.shutdown()`, `ROS2Node.destroy()` and `ROS2ParameterClient.close()`
used to make their transport closes on Swift's cooperative pool. A close can
block for as long as the link stalls (a wire Zenoh publisher close waits for a
put stuck on a frozen TCP link), so as many concurrent teardowns as there are
CPU cores stalled every task on the global concurrent executor. The closes now
run on a serial dispatch queue owned by the context, and the functions suspend
until the closes have finished. The close order is unchanged: each node's
entities, then its unregistration, then the session.

**The teardowns of one context run one at a time.** A second `shutdown()`
returns only after the first one's closes (before, it could close the session
while the first was still closing entities), and a node's `destroy()` waits for
a teardown of the same context that started earlier. A context whose close is
stuck does not delay the teardown of another context.

**Do not block a swift-ros2 callback until a teardown of the same context
finishes.** If a close that runs ahead of that teardown waits for the callback,
as a publisher close does for an `onMatchedSubscriptionsChanged` handler call
that is running, neither ever finishes.

A close that never returns still never returns: it now holds one dispatch
thread per stuck context instead of a cooperative-pool thread, and the awaiting
task stays suspended. Creating nodes and entities still makes its transport
calls on the caller's thread.

**The binary targets stay on the 2.3.0 assets.** `Package.swift` keeps the
2.3.0 `binaryTarget` URLs and checksums, because 2.3.2 changes only Swift code.
