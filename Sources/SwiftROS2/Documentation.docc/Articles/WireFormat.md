# Wire format

What SwiftROS2 puts on the wire to interoperate with `rmw_zenoh_cpp` and
`rmw_cyclonedds_cpp`.

## Zenoh key expression

Format: `<domain>/<namespace>/<topic>/<dds_type_name>/<type_hash>`.

The DDS type name uses the `::msg::dds_::Type_` form (e.g.
`sensor_msgs::msg::dds_::Imu_`). On Humble, the type-hash segment is the
literal `TypeHashNotSupported`. On Jazzy and later, it is the
`RIHS01_<hex>` value or the segment is omitted entirely if no hash is
known.

## Attachment (33 bytes)

Layout (Zenoh `ext::Serializer`):

| Bytes | Meaning |
|---|---|
| 0–7   | seq (Int64, little-endian) |
| 8–15  | timestamp_ns (Int64, little-endian) |
| 16    | `0x10` LEB128 length prefix for the 16-byte GID array |
| 17–32 | publisher GID (16 raw bytes) |

The GID is the one `rmw_zenoh_cpp` gives the entity: the XXH3 128-bit hash
of its liveliness token (see below), low 64 bits then high 64 bits,
little-endian. Every publisher and every service or action client has its
own, the one `ros2 topic info -v` shows.

## Zenoh services and actions

A service is a queryable on
`<domain>/<namespace>/<service>/<pkg>::srv::dds_::<Type>_/<service_type_hash>`:
the service type (not its request type) and the hash of the service type
itself (`ROS2ServiceTypeInfo.serviceTypeHash`), as `rmw_zenoh_cpp` keys it.
On Humble the hash segment is `TypeHashNotSupported`.

An action is three services and two topics under `<action>/_action/`:

| Role | DDS type | Hash |
|---|---|---|
| `send_goal` | `<pkg>::action::dds_::<Action>_SendGoal_` | `sendGoalServiceTypeHash` |
| `get_result` | `<pkg>::action::dds_::<Action>_GetResult_` | `getResultServiceTypeHash` |
| `cancel_goal` | `action_msgs::srv::dds_::CancelGoal_` | `CancelGoal` service hash |
| `feedback` | `<pkg>::action::dds_::<Action>_FeedbackMessage_` | feedback message hash |
| `status` | `action_msgs::msg::dds_::GoalStatusArray_` | `GoalStatusArray` hash |

Every request and every reply carries the 33-byte attachment: a request
carries the client's sequence number and GID, and the reply echoes them.
`rmw_zenoh_cpp` rejects requests without one and drops replies without one.

Each endpoint declares the liveliness token `rmw_zenoh_cpp` discovers it by,
`@ros2_lv/<domain>/<session>/<node_id>/<entity_id>/<kind>/%/<node_namespace>/<node_name>/<name>/<type>/<hash>/<qos>`
with `/` mangled to `%`: `MP` for a publisher, `MS` for a subscription (on
Lyrical and later followed by `/backends:cpu:`, the CPU-only buffer-aware
form), `SS` for a service server and `SC` for a service client; an action
declares the tokens of its three services and two topics. The node namespace
and name are those of the owning ``ROS2Node``, so `ros2 node info` lists its
publishers, subscriptions, services and actions. Each node also declares
`@ros2_lv/<domain>/<session>/<node_id>/<node_id>/NN/%/<node_namespace>/<node_name>`:
`rmw_zenoh_cpp` removes a node from its graph only when that token goes. A
client waits for a server by querying the `SS` tokens.

A service or action type generated without service type hashes (by a
swift-ros2-gen older than swift-ros2-rosidl 1.0.0-rc.2) has only its request
hash. On Jazzy and later such a type keeps the request-typed key
`<service>/<pkg>::srv::dds_::<Type>_Request_/<request_type_hash>` used before,
and a message is logged once per type. Only swift-ros2 peers answer that key;
regenerate the type to reach `rmw_zenoh_cpp`.

## CDR encoding

XCDR v1, explicit little-endian. Every payload starts with the four-byte
encapsulation header `00 01 00 00`. Fixed-size arrays serialize without a
length prefix; sequences carry a four-byte `uint32` length prefix.

## DDS topic and type names

- Topic: `rt/<topic>` (the `rt/` prefix marks it as a ROS 2 topic).
- Type: same `pkg::msg::dds_::Type_` form as Zenoh.
- Type hash: encoded as USER_DATA `typehash=RIHS01_<hex>;`.
