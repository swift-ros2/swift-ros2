#!/usr/bin/env bash
# Regenerate CRclBridge's name-keyed RCL type-support registries: the message
# registry (crcl_marshal_resolve_typesupport), the M7 service typesupport
# registry, and the M8 action typesupport registry. Every message type is
# published through the rmw serialized seam; no per-type marshalling is
# generated. Run from the repo root. The same invocation backs the ci-rcl
# drift guard.
#
# The action IDL stays on the Jazzy vendor tree although the Apple RCL stack
# is Lyrical: for every registry type the Lyrical IDL is identical, and the
# generated files carry no distro label.
set -euo pipefail
# M7 (spec section 20.3) service set: the six rcl_interfaces parameter
# services, std_srvs, example_interfaces/AddTwoInts, sensor_msgs/SetCameraInfo,
# and action_msgs/CancelGoal (M8 prep).
SRV_TYPES="rcl_interfaces/srv/DescribeParameters"
SRV_TYPES+=",rcl_interfaces/srv/GetParameterTypes"
SRV_TYPES+=",rcl_interfaces/srv/GetParameters"
SRV_TYPES+=",rcl_interfaces/srv/ListParameters"
SRV_TYPES+=",rcl_interfaces/srv/SetParameters"
SRV_TYPES+=",rcl_interfaces/srv/SetParametersAtomically"
SRV_TYPES+=",std_srvs/srv/Empty"
SRV_TYPES+=",std_srvs/srv/SetBool"
SRV_TYPES+=",std_srvs/srv/Trigger"
SRV_TYPES+=",example_interfaces/srv/AddTwoInts"
SRV_TYPES+=",sensor_msgs/srv/SetCameraInfo"
SRV_TYPES+=",action_msgs/srv/CancelGoal"
# M8 (spec section 20.6) action set: example_interfaces/Fibonacci is the only
# consumer (the in-process loopback gate + the ros2 action send_goal runbook).
ACTION_TYPES="example_interfaces/action/Fibonacci"
# Messages that get a typesupport entry without marshal functions — published
# and subscribed over the rmw serialized seam (still fully route-a through
# rcl/rmw). Covers every SwiftROS2Messages type whose package typesupport is
# bundled in CRos2.xcframework, including the three Conduit-critical
# packages (tf2_msgs, audio_common_msgs, point_cloud_interfaces) added to
# PKGS_UP_TO in Scripts/build-ros2-xcframework.sh. Skipped: action_msgs
# GoalInfo/GoalStatus and unique_identifier_msgs/UUID (nested-only — no
# standalone ROS2Message conformance in SwiftROS2Messages).
REGISTRY_ONLY_TYPES="rcl_interfaces/msg/ParameterEvent"
REGISTRY_ONLY_TYPES+=",action_msgs/msg/GoalStatusArray"
REGISTRY_ONLY_TYPES+=",audio_common_msgs/msg/AudioData"
REGISTRY_ONLY_TYPES+=",builtin_interfaces/msg/Time"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Accel"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Point"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Point32"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Pose"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/PoseStamped"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Quaternion"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Transform"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/TransformStamped"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Twist"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/TwistStamped"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Vector3"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Vector3Stamped"
REGISTRY_ONLY_TYPES+=",geometry_msgs/msg/Wrench"
REGISTRY_ONLY_TYPES+=",point_cloud_interfaces/msg/CompressedPointCloud2"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/FloatingPointRange"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/IntegerRange"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/ListParametersResult"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/Parameter"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/ParameterDescriptor"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/ParameterEventDescriptors"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/ParameterType"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/ParameterValue"
REGISTRY_ONLY_TYPES+=",rcl_interfaces/msg/SetParametersResult"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/ChannelFloat32"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/JointState"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/JoyFeedback"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/JoyFeedbackArray"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/LaserEcho"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/LaserScan"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/MultiDOFJointState"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/MultiEchoLaserScan"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/NavSatStatus"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/PointCloud"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/PointField"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/RegionOfInterest"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/RelativeHumidity"
REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/TimeReference"
REGISTRY_ONLY_TYPES+=",std_msgs/msg/Bool"
REGISTRY_ONLY_TYPES+=",std_msgs/msg/Empty"
REGISTRY_ONLY_TYPES+=",std_msgs/msg/Float64"
REGISTRY_ONLY_TYPES+=",std_msgs/msg/Header"
REGISTRY_ONLY_TYPES+=",std_msgs/msg/Int32"
REGISTRY_ONLY_TYPES+=",std_msgs/msg/String"
REGISTRY_ONLY_TYPES+=",tf2_msgs/msg/TFMessage"
# The 13 sensor_msgs types that used the typed path now resolve by name like every other type.
for t in Imu Joy BatteryState CompressedImage PointCloud2 MagneticField FluidPressure Illuminance NavSatFix Range Temperature Image CameraInfo; do
  REGISTRY_ONLY_TYPES+=",sensor_msgs/msg/$t"
done
# The examples publish example_interfaces/msg/String and serve example_interfaces/srv/Trigger.
# example_interfaces is in PKGS_UP_TO (Scripts/build-ros2-xcframework.sh) and the
# Linux link lists, so its C type support is bundled; without these entries `talker rcl`,
# `listener rcl`, `srv-server rcl` and `srv-client rcl` fail type-support lookup.
REGISTRY_ONLY_TYPES+=",example_interfaces/msg/String"
SRV_TYPES+=",example_interfaces/srv/Trigger"
swift run rcl-registry-gen \
  --msg-types "$REGISTRY_ONLY_TYPES" --srv-types "$SRV_TYPES" --action-types "$ACTION_TYPES" \
  --action-idl "example_interfaces=vendor/example_interfaces-jazzy" \
  --c-output Sources/CRclBridge
